import { IRequest, Router } from 'itty-router';
import { z } from 'zod';
import type { Env, AuthenticatedRequest, MessageRow } from '../types.js';
import { authMiddleware } from '../middleware/auth.js';
import { isActiveV2Device, resolveRequestDevice } from '../middleware/device.js';
import { generateId } from '../utils/crypto.js';
import {
  getMessageEditDenial,
  getMessageSendDenial,
} from '../services/messagePermissions.js';
import { notifyInboxes } from '../services/inbox.js';
import { deleteMessages } from '../services/message_deletion.js';
import { sendMessagePush } from '../services/push.js';
import { getConversationAccess, getConversationForMember } from './conversations.js';
import { readJsonBody } from '../utils/http.js';
import { postChatRoomJson } from '../utils/durableObject.js';
import { runBatched } from '../utils/d1.js';
import { validateConversationEnvelope } from '../services/conversationKeys.js';

export const messagesRouter = Router({ base: '/api/conversations' });

const MAX_CIPHERTEXT_CHARS = 64 * 1024;

const conversationKeyMessageSchema = z.object({
  encryptionVersion: z.literal(2),
  id: z.string().uuid('Message ID must be a UUID'),
  ciphertext: z.string().min(1).max(MAX_CIPHERTEXT_CHARS),
  nonce: z.string().min(1).max(128),
  authTag: z.string().min(1).max(128),
  keyEpoch: z.number().int().positive(),
  recipientId: z.string().uuid('recipientId must be a valid UUID'),
  mediaId: z.string().uuid('mediaId must be a valid UUID').nullable().optional(),
  replyToId: z.string().uuid().nullable().optional(),
});

const conversationKeyEditSchema = z.object({
  encryptionVersion: z.literal(2),
  ciphertext: z.string().min(1).max(MAX_CIPHERTEXT_CHARS),
  nonce: z.string().min(1).max(128),
  authTag: z.string().min(1).max(128),
  keyEpoch: z.number().int().positive(),
  version: z.number().int().positive(),
});

const deleteForMeSchema = z.object({
  messageIds: z.array(z.string().uuid()).min(1).max(100),
});

const reactionSchema = z.object({
  emoji: z.string().min(1).max(10),
});

function rowToResponse(row: MessageRow) {
  return {
    id: row.id,
    conversationId: row.conversation_id,
    senderId: row.sender_id,
    senderDeviceId: row.sender_device_id ?? null,
    encryptedPayload: row.ciphertext ?? null,
    encryptionVersion: 2,
    ciphertext: row.ciphertext ?? null,
    nonce: row.nonce ?? null,
    authTag: row.auth_tag ?? null,
    keyEpoch: row.key_epoch ?? null,
    messageType: row.message_type,
    replyToId: row.reply_to_id,
    version: row.version,
    isUnsent: row.is_unsent === 1,
    createdAt: row.created_at,
    expiresAt: row.expires_at,
    editedAt: row.edited_at,
    systemData: row.system_data,
    deliveredAt: row.delivered_at ?? null,
    readAt: row.read_at ?? null,
    reaction: row.reaction ?? null,
    isSentByMe: row.is_sent_by_me === 1,
  };
}

messagesRouter.get(
  '/:id/messages',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const { id: conversationId } = request.params as { id: string };

    const conv = await getConversationForMember(conversationId, userId, env.DB);
    if (!conv) {
      return new Response(JSON.stringify({ error: 'Conversation not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const requestDevice = await resolveRequestDevice(request, env, userId);
    if (!requestDevice || !requestDevice.identity_public_key) {
      return new Response(JSON.stringify({ error: 'Device registration required' }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const url = new URL(request.url);
    const before = url.searchParams.get('before');
    const beforeCreatedAtRaw = url.searchParams.get('beforeCreatedAt');
    const beforeCreatedAtValue =
      beforeCreatedAtRaw == null ? null : Number.parseInt(beforeCreatedAtRaw, 10);
    const beforeCreatedAt = Number.isFinite(beforeCreatedAtValue) ? beforeCreatedAtValue : null;
    const afterRaw = url.searchParams.get('after');
    const afterValue = afterRaw == null ? null : Number.parseInt(afterRaw, 10);
    const after = Number.isFinite(afterValue) ? afterValue : null;
    const limitRaw = parseInt(url.searchParams.get('limit') ?? '50', 10);
    const limit = Math.min(Math.max(1, isNaN(limitRaw) ? 50 : limitRaw), 100);
    const now = Math.floor(Date.now() / 1000);

    let rows: D1Result<MessageRow>;

    if (before) {
      const cursorMsg = await env.DB.prepare(
        'SELECT created_at, id FROM messages WHERE id = ? AND conversation_id = ?',
      )
        .bind(before, conversationId)
        .first<{ created_at: number; id: string }>();

      if (!cursorMsg && beforeCreatedAt == null) {
        return new Response(JSON.stringify({ error: 'Cursor message not found' }), {
          status: 404,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      const cursorCreatedAt = cursorMsg?.created_at ?? beforeCreatedAt!;
      const cursorId = cursorMsg?.id ?? before;
      // Overlap the second if the cursor row vanished so same-second pagination leaves no gap.
      const includeCursorSecond = cursorMsg == null ? 1 : 0;

      rows = await env.DB.prepare(
        `SELECT m.*,
           (m.sender_id = ?) AS is_sent_by_me
         FROM messages m
         LEFT JOIN local_deletions ld
           ON ld.message_id = m.id AND ld.user_id = ?
         WHERE m.conversation_id = ?
           AND ld.id IS NULL
           AND m.is_unsent = 0
           AND m.message_type != 'system'
           AND (m.expires_at IS NULL OR m.expires_at > ?)
           AND (? IS NULL OR m.created_at >= ?)
           AND (m.created_at < ? OR (m.created_at = ? AND m.id < ?) OR (m.created_at = ? AND ? = 1))
         ORDER BY m.created_at DESC, m.id DESC
         LIMIT ?`,
      )
        .bind(
          userId,
          userId,
          conversationId,
          now,
          after,
          after,
          cursorCreatedAt,
          cursorCreatedAt,
          cursorId,
          cursorCreatedAt,
          includeCursorSecond,
          limit,
        )
        .all<MessageRow>();
    } else {
      rows = await env.DB.prepare(
        `SELECT m.*,
           (m.sender_id = ?) AS is_sent_by_me
         FROM messages m
         LEFT JOIN local_deletions ld
           ON ld.message_id = m.id AND ld.user_id = ?
         WHERE m.conversation_id = ?
           AND ld.id IS NULL
           AND m.is_unsent = 0
           AND m.message_type != 'system'
           AND (m.expires_at IS NULL OR m.expires_at > ?)
           AND (? IS NULL OR m.created_at >= ?)
         ORDER BY m.created_at DESC, m.id DESC
         LIMIT ?`,
      )
        .bind(userId, userId, conversationId, now, after, after, limit)
        .all<MessageRow>();
    }

    const messages = (rows.results ?? []).map(rowToResponse);
    return new Response(JSON.stringify(messages), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  },
);

messagesRouter.post(
  '/:id/messages',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const { id: conversationId } = request.params as { id: string };

    const conv = await getConversationAccess(conversationId, userId, env.DB);
    if (!conv) {
      return new Response(JSON.stringify({ error: 'Conversation not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const expectedRecipient =
      conv.user_a_id === userId ? conv.user_b_id : conv.user_a_id;

    let hasExistingMessage = false;
    if (conv.request_status === 'pending' && conv.initiated_by_id === userId) {
      hasExistingMessage = conv.last_message_at != null;
      if (!hasExistingMessage) {
        const existingMessage = await env.DB.prepare(
          'SELECT id FROM messages WHERE conversation_id = ? LIMIT 1',
        )
          .bind(conversationId)
          .first<{ id: string }>();
        hasExistingMessage = existingMessage != null;
      }
    }

    const sendDenial = getMessageSendDenial({
      requestStatus: conv.request_status,
      initiatedById: conv.initiated_by_id,
      userId,
      hasExistingMessage,
      isBlocked: conv.is_blocked === 1,
    });
    if (
      sendDenial === 'rejected_request' ||
      sendDenial === 'recipient_has_not_accepted'
    ) {
      return new Response(JSON.stringify({ error: 'Accept the message request before replying' }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    if (sendDenial === 'initial_request_already_sent') {
      return new Response(
        JSON.stringify({ error: 'Wait for the recipient to accept your request' }),
        { status: 409, headers: { 'Content-Type': 'application/json' } },
      );
    }
    if (sendDenial === 'blocked_chat') {
      return new Response(JSON.stringify({ error: "You can't message this account" }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const bodyResult = await readJsonBody(request);
    if (!bodyResult.ok) return bodyResult.response;

    const v2Parsed = conversationKeyMessageSchema.safeParse(bodyResult.body);
    if (!v2Parsed.success) {
      return new Response(
        JSON.stringify({ error: 'Validation failed', details: v2Parsed.error.flatten() }),
        { status: 400, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const envelope = validateConversationEnvelope(
      v2Parsed.data as unknown as Record<string, unknown>,
    );
    if (!envelope.ok) {
      return new Response(JSON.stringify({ error: envelope.error }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const v2 = v2Parsed.data;
    if (v2.recipientId !== expectedRecipient) {
      return new Response(JSON.stringify({ error: 'Invalid recipientId' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const device = await resolveRequestDevice(request, env, userId);
    if (!isActiveV2Device(device)) {
      return new Response(JSON.stringify({ error: 'Active conversation-key device required' }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const [existingResult, mediaResult, coverageResult] = await env.DB.batch([
      env.DB.prepare(
        'SELECT id, sender_id, conversation_id FROM messages WHERE id = ?',
      ).bind(v2.id),
      v2.mediaId
        ? env.DB.prepare(
            `SELECT id FROM media
             WHERE id = ? AND conversation_id = ? AND sender_id = ? AND consumed = 0`,
          ).bind(v2.mediaId, conversationId, userId)
        : env.DB.prepare('SELECT NULL AS id WHERE 0'),
      env.DB.prepare(
        `SELECT
           (SELECT COUNT(*) FROM devices
            WHERE user_id IN (?, ?) AND status = 'active' AND identity_public_key IS NOT NULL) AS active_count,
           (SELECT COUNT(*) FROM devices
            WHERE user_id = ? AND status = 'active' AND identity_public_key IS NOT NULL) AS sender_count,
           (SELECT COUNT(*) FROM devices
            WHERE user_id = ? AND status = 'active' AND identity_public_key IS NOT NULL) AS recipient_count,
           (SELECT COUNT(*) FROM device_key_envelopes e
            JOIN devices d ON d.id = e.recipient_device_id
            WHERE e.conversation_id = ? AND e.epoch = ?
              AND d.user_id IN (?, ?) AND d.status = 'active'
              AND d.identity_public_key IS NOT NULL) AS envelope_count`,
      ).bind(
        userId,
        expectedRecipient,
        userId,
        expectedRecipient,
        conversationId,
        v2.keyEpoch,
        userId,
        expectedRecipient,
      ),
    ]);

    const existingMessage = existingResult.results?.[0] as
      | { id: string; sender_id: string; conversation_id: string }
      | undefined;
    if (existingMessage) {
      if (
        existingMessage.sender_id !== userId ||
        existingMessage.conversation_id !== conversationId
      ) {
        return new Response(JSON.stringify({ error: 'Message id conflict' }), {
          status: 409,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      return new Response(JSON.stringify({ id: v2.id, status: 'already_committed' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    if (v2.mediaId && !mediaResult.results?.length) {
      return new Response(JSON.stringify({ error: 'Invalid mediaId' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    if (conv.key_rotation_required === 1) {
      return new Response(JSON.stringify({ error: 'key_rotation_required' }), {
        status: 409,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    if (v2.keyEpoch !== conv.key_epoch || conv.key_epoch < 1) {
      return new Response(
        JSON.stringify({
          error: 'key_epoch_conflict',
          currentEpoch: conv.key_epoch,
        }),
        { status: 409, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const coverage = coverageResult.results?.[0] as
      | {
          active_count: number;
          sender_count: number;
          recipient_count: number;
          envelope_count: number;
        }
      | undefined;
    if (
      !coverage ||
      coverage.sender_count < 1 ||
      coverage.recipient_count < 1 ||
      coverage.active_count !== coverage.envelope_count
    ) {
      return new Response(JSON.stringify({ error: 'conversation_keys_not_provisioned' }), {
        status: 409,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const now = Math.floor(Date.now() / 1000);
    // Disappearing timers arm on read, not on send.
    const expiresAt = null;
    try {
      await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO messages
             (id, conversation_id, sender_id, sender_device_id, message_type,
              reply_to_id, media_id, version, is_unsent, created_at, expires_at,
              ciphertext, nonce, auth_tag, key_epoch)
           VALUES (?, ?, ?, ?, 'signal', ?, ?, 1, 0, ?, ?, ?, ?, ?, ?)`,
        ).bind(
          v2.id,
          conversationId,
          userId,
          device.id,
          v2.replyToId ?? null,
          v2.mediaId ?? null,
          now,
          expiresAt,
          v2.ciphertext,
          v2.nonce,
          v2.authTag,
          v2.keyEpoch,
        ),
        env.DB.prepare(
          'UPDATE conversations SET last_message_at = ?, last_message_sender_id = ? WHERE id = ?',
        ).bind(now, userId, conversationId),
        env.DB.prepare(
          `INSERT INTO conversation_user_state (conversation_id, user_id, unread_count)
           VALUES (?, ?, 1)
           ON CONFLICT(conversation_id, user_id) DO UPDATE SET
             unread_count = conversation_user_state.unread_count + 1`,
        ).bind(conversationId, expectedRecipient),
        env.DB.prepare(
          `INSERT OR IGNORE INTO conversation_user_state (conversation_id, user_id, unread_count)
           VALUES (?, ?, 0)`,
        ).bind(conversationId, userId),
        ...(v2.mediaId
          ? [
              env.DB.prepare(
                'UPDATE media SET consumed = 1 WHERE id = ? AND conversation_id = ? AND sender_id = ?',
              ).bind(v2.mediaId, conversationId, userId),
            ]
          : []),
      ]);
    } catch {
      const duplicate = await env.DB.prepare(
        'SELECT sender_id, conversation_id FROM messages WHERE id = ?',
      )
        .bind(v2.id)
        .first<{ sender_id: string; conversation_id: string }>();
      if (duplicate?.sender_id === userId && duplicate.conversation_id === conversationId) {
        return new Response(JSON.stringify({ id: v2.id, status: 'already_committed' }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      return new Response(JSON.stringify({ error: 'Message persistence failed' }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const event = {
      type: 'new_message' as const,
      messageId: v2.id,
      conversationId,
      senderId: userId,
      senderDeviceId: device.id,
      recipients: [userId, expectedRecipient],
      encryptionVersion: 2,
      ciphertext: v2.ciphertext,
      nonce: v2.nonce,
      authTag: v2.authTag,
      keyEpoch: v2.keyEpoch,
      messageType: 'signal',
      replyToId: v2.replyToId ?? null,
      createdAt: now,
      expiresAt,
    };
    await postChatRoomJson(env, conversationId, '/broadcast', { events: [event] });

    const activeUsers = await notifyInboxes(env, [userId, expectedRecipient], (targetUserId) => [
      {
        type: 'inbox_message',
        conversationId,
        senderId: userId,
        preview: 'New message',
        lastMessageAt: now,
        isIncoming: targetUserId !== userId,
      },
    ]);
    await sendMessagePush(env, {
      senderId: userId,
      recipientId: expectedRecipient,
      conversationId,
      recipientHasActiveSocket: activeUsers.has(expectedRecipient),
    });

    return new Response(
      JSON.stringify({
        id: v2.id,
        conversationId,
        senderId: userId,
        senderDeviceId: device.id,
        encryptedPayload: v2.ciphertext,
        ciphertext: v2.ciphertext,
        nonce: v2.nonce,
        authTag: v2.authTag,
        encryptionVersion: 2,
        keyEpoch: v2.keyEpoch,
        messageType: 'signal',
        replyToId: v2.replyToId ?? null,
        version: 1,
        isUnsent: false,
        createdAt: now,
        expiresAt,
        editedAt: null,
        systemData: null,
        deliveredAt: null,
        readAt: null,
        isSentByMe: true,
      }),
      { status: 201, headers: { 'Content-Type': 'application/json' } },
    );
  },
);

messagesRouter.post(
  '/:id/messages/delete-for-me',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const { id: conversationId } = request.params as { id: string };
    const conversation = await getConversationForMember(conversationId, userId, env.DB);
    if (!conversation) {
      return new Response(JSON.stringify({ error: 'Conversation not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const bodyResult = await readJsonBody(request);
    if (!bodyResult.ok) return bodyResult.response;
    const parsed = deleteForMeSchema.safeParse(bodyResult.body);
    if (!parsed.success) {
      return new Response(JSON.stringify({ error: 'Invalid message IDs' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const messageIds = [...new Set(parsed.data.messageIds)];
    const matching = await env.DB.prepare(
      `SELECT id FROM messages
       WHERE conversation_id = ? AND id IN (SELECT value FROM json_each(?))`,
    )
      .bind(conversationId, JSON.stringify(messageIds))
      .all<{ id: string }>();
    if ((matching.results ?? []).length !== messageIds.length) {
      return new Response(JSON.stringify({ error: 'One or more messages were not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const now = Math.floor(Date.now() / 1000);
    await runBatched(
      env.DB,
      messageIds.map((messageId) =>
        env.DB.prepare(
          `INSERT OR IGNORE INTO local_deletions (id, user_id, message_id, deleted_at)
           VALUES (?, ?, ?, ?)`,
        ).bind(generateId(), userId, messageId, now),
      ),
    );

    return new Response(JSON.stringify({ deleted: messageIds.length, scope: 'local' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  },
);

messagesRouter.post(
  '/:id/read',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const { id: conversationId } = request.params as { id: string };
    const conversation = await getConversationAccess(conversationId, userId, env.DB);
    if (!conversation) {
      return new Response(JSON.stringify({ error: 'Conversation not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    if (conversation.request_status === 'pending') {
      return new Response(JSON.stringify({ read: false, reason: 'pending_request' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    if (conversation.is_blocked === 1) {
      return new Response(JSON.stringify({ read: false, reason: 'blocked' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const now = Math.floor(Date.now() / 1000);
    const peerId =
      conversation.user_a_id === userId ? conversation.user_b_id : conversation.user_a_id;

    const [unreadRows] = await env.DB.batch<{ id: string }>([
      env.DB.prepare(
        `SELECT id FROM messages
         WHERE conversation_id = ? AND sender_id != ? AND is_unsent = 0 AND read_at IS NULL`,
      ).bind(conversationId, userId),
      env.DB.prepare(
        `UPDATE messages
         SET delivered_at = COALESCE(delivered_at, ?), read_at = ?
         WHERE conversation_id = ? AND sender_id != ? AND is_unsent = 0 AND read_at IS NULL`,
      ).bind(now, now, conversationId, userId),
    ]);

    const newlyReadMessageIds = (unreadRows.results ?? []).map((row) => row.id);

    if (newlyReadMessageIds.length > 0) {
      await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO conversation_user_state (conversation_id, user_id, unread_count, last_read_at)
           VALUES (?, ?, 0, ?)
           ON CONFLICT(conversation_id, user_id) DO UPDATE SET
             unread_count = 0,
             last_read_at = MAX(COALESCE(conversation_user_state.last_read_at, 0), excluded.last_read_at)`,
        ).bind(conversationId, userId, now),
        env.DB.prepare(
          `INSERT INTO conversation_user_state (conversation_id, user_id, unread_count, peer_seen_at)
           VALUES (?, ?, 0, ?)
           ON CONFLICT(conversation_id, user_id) DO UPDATE SET
             peer_seen_at = MAX(COALESCE(conversation_user_state.peer_seen_at, 0), excluded.peer_seen_at)`,
        ).bind(conversationId, peerId, now),
      ]);

      await postChatRoomJson(env, conversationId, '/broadcast', {
        events: [
          {
            type: 'messages_read',
            conversationId,
            readBy: userId,
            readAt: now,
          },
        ],
      });

      if (conversation.disappearing_timer === -1) {
        await deleteMessages(env, conversationId, newlyReadMessageIds);
      } else if (conversation.disappearing_timer > 0) {
        await env.DB.prepare(
          `UPDATE messages SET expires_at = ?
           WHERE id IN (SELECT value FROM json_each(?))`,
        )
          .bind(now + conversation.disappearing_timer, JSON.stringify(newlyReadMessageIds))
          .run();
      }

      await notifyInboxes(env, [userId], () => [
        {
          type: 'unread_reset',
          conversationId,
        },
      ]);
    } else {
      await env.DB.prepare(
        `UPDATE conversation_user_state SET unread_count = 0
         WHERE conversation_id = ? AND user_id = ? AND unread_count != 0`,
      )
        .bind(conversationId, userId)
        .run();
    }

    return new Response(JSON.stringify({ read: true, readAt: now }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  },
);

messagesRouter.patch(
  '/:id/messages/:messageId',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const { id: conversationId, messageId } = request.params as {
      id: string;
      messageId: string;
    };

    const conv = await getConversationForMember(conversationId, userId, env.DB);
    if (!conv) {
      return new Response(JSON.stringify({ error: 'Conversation not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const message = await env.DB.prepare(
      `SELECT * FROM messages WHERE id = ? AND conversation_id = ?`,
    )
      .bind(messageId, conversationId)
      .first<MessageRow>();

    if (!message) {
      return new Response(JSON.stringify({ error: 'Message not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const now = Math.floor(Date.now() / 1000);
    const editDenial = getMessageEditDenial({
      senderId: message.sender_id,
      userId,
      isUnsent: message.is_unsent === 1,
      createdAt: message.created_at,
      now,
    });

    if (editDenial === 'not_sender') {
      return new Response(JSON.stringify({ error: 'Forbidden: not the message sender' }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    if (editDenial === 'unsent') {
      return new Response(JSON.stringify({ error: 'Cannot edit an unsent message' }), {
        status: 409,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    if (editDenial === 'expired') {
      return new Response(JSON.stringify({ error: 'Message edit window has expired' }), {
        status: 409,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const bodyResult = await readJsonBody(request);
    if (!bodyResult.ok) return bodyResult.response;

    const parsedV2 = conversationKeyEditSchema.safeParse(bodyResult.body);
    if (!parsedV2.success) {
      return new Response(
        JSON.stringify({ error: 'Validation failed', details: parsedV2.error.flatten() }),
        { status: 400, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const envelope = validateConversationEnvelope(
      parsedV2.data as unknown as Record<string, unknown>,
    );
    if (!envelope.ok) {
      return new Response(JSON.stringify({ error: envelope.error }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    if (message.version !== parsedV2.data.version) {
      return new Response(
        JSON.stringify({
          error: 'Conflict: message has been modified. Fetch latest and retry.',
          currentVersion: message.version,
        }),
        { status: 409, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const device = await resolveRequestDevice(request, env, userId);
    if (!isActiveV2Device(device)) {
      return new Response(JSON.stringify({ error: 'Active conversation-key device required' }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    if (conv.key_rotation_required === 1) {
      return new Response(JSON.stringify({ error: 'key_rotation_required' }), {
        status: 409,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    if (parsedV2.data.keyEpoch !== conv.key_epoch || parsedV2.data.keyEpoch < 1) {
      return new Response(
        JSON.stringify({
          error: 'key_epoch_conflict',
          currentEpoch: conv.key_epoch,
        }),
        { status: 409, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const nextVersion = parsedV2.data.version + 1;
    const updated = await env.DB.prepare(
      `UPDATE messages
       SET ciphertext = ?, nonce = ?, auth_tag = ?, key_epoch = ?,
           version = ?, edited_at = ?
       WHERE id = ? AND conversation_id = ? AND sender_id = ? AND version = ?`,
    )
      .bind(
        parsedV2.data.ciphertext,
        parsedV2.data.nonce,
        parsedV2.data.authTag,
        parsedV2.data.keyEpoch,
        nextVersion,
        now,
        messageId,
        conversationId,
        userId,
        parsedV2.data.version,
      )
      .run();

    if ((updated.meta.changes ?? 0) !== 1) {
      return new Response(JSON.stringify({ error: 'message_version_conflict' }), {
        status: 409,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const recipientId = conv.user_a_id === userId ? conv.user_b_id : conv.user_a_id;
    await postChatRoomJson(env, conversationId, '/broadcast', {
      events: [
        {
          type: 'message_edited',
          messageId,
          conversationId,
          recipients: [userId, recipientId],
          encryptionVersion: 2,
          ciphertext: parsedV2.data.ciphertext,
          nonce: parsedV2.data.nonce,
          authTag: parsedV2.data.authTag,
          keyEpoch: parsedV2.data.keyEpoch,
          messageType: 'signal',
          version: nextVersion,
          editedAt: now,
        },
      ],
    });

    return new Response(
      JSON.stringify({
        id: messageId,
        conversationId,
        senderId: userId,
        senderDeviceId: message.sender_device_id,
        encryptedPayload: parsedV2.data.ciphertext,
        ciphertext: parsedV2.data.ciphertext,
        nonce: parsedV2.data.nonce,
        authTag: parsedV2.data.authTag,
        encryptionVersion: 2,
        keyEpoch: parsedV2.data.keyEpoch,
        messageType: 'signal',
        version: nextVersion,
        editedAt: now,
        isSentByMe: true,
      }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  },
);

messagesRouter.delete(
  '/:id/messages/:messageId',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const { id: conversationId, messageId } = request.params as {
      id: string;
      messageId: string;
    };

    const url = new URL(request.url);
    const localOnly = url.searchParams.get('local') === 'true';

    const conv = await getConversationForMember(conversationId, userId, env.DB);
    if (!conv) {
      return new Response(JSON.stringify({ error: 'Conversation not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const message = await env.DB.prepare(
      `SELECT * FROM messages WHERE id = ? AND conversation_id = ?`,
    )
      .bind(messageId, conversationId)
      .first<MessageRow>();

    if (!message) {
      return new Response(JSON.stringify({ error: 'Message not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const now = Math.floor(Date.now() / 1000);

    if (localOnly) {
      await env.DB.prepare(
        `INSERT OR IGNORE INTO local_deletions (id, user_id, message_id, deleted_at)
         VALUES (?, ?, ?, ?)`,
      )
        .bind(generateId(), userId, messageId, now)
        .run();

      return new Response(JSON.stringify({ deleted: true, scope: 'local' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    if (message.sender_id !== userId) {
      return new Response(JSON.stringify({ error: 'Forbidden: only the sender can unsend' }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    await deleteMessages(env, conversationId, [messageId]);

    return new Response(JSON.stringify({ deleted: true, scope: 'global' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  },
);

messagesRouter.post(
  '/:id/messages/:messageId/reaction',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const { id: conversationId, messageId } = request.params as {
      id: string;
      messageId: string;
    };

    const conv = await getConversationForMember(conversationId, userId, env.DB);
    if (!conv) {
      return new Response(JSON.stringify({ error: 'Conversation not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const message = await env.DB.prepare(
      `SELECT * FROM messages WHERE id = ? AND conversation_id = ?`,
    )
      .bind(messageId, conversationId)
      .first<MessageRow>();

    if (!message) {
      return new Response(JSON.stringify({ error: 'Message not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    if (message.is_unsent === 1) {
      return new Response(JSON.stringify({ error: 'Cannot react to unsent message' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const bodyResult = await readJsonBody(request);
    if (!bodyResult.ok) return bodyResult.response;

    const parsed = reactionSchema.safeParse(bodyResult.body);
    if (!parsed.success) {
      return new Response(
        JSON.stringify({ error: 'Invalid body', details: parsed.error.issues }),
        { status: 400, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const { emoji } = parsed.data;
    const now = Math.floor(Date.now() / 1000);

    const existing = await env.DB.prepare(
      `SELECT id, emoji FROM message_reactions WHERE message_id = ? AND user_id = ?`,
    )
      .bind(messageId, userId)
      .first<{ id: string; emoji: string }>();

    let resultingReaction: string | null = emoji;

    if (existing && existing.emoji === emoji) {
      await env.DB.prepare(`DELETE FROM message_reactions WHERE id = ?`).bind(existing.id).run();

      const otherReaction = await env.DB.prepare(
        `SELECT emoji FROM message_reactions WHERE message_id = ? ORDER BY updated_at DESC LIMIT 1`,
      )
        .bind(messageId)
        .first<{ emoji: string }>();

      resultingReaction = otherReaction?.emoji ?? null;
      await env.DB.prepare(`UPDATE messages SET reaction = ? WHERE id = ?`)
        .bind(resultingReaction, messageId)
        .run();

      await postChatRoomJson(env, conversationId, '/broadcast', {
        events: [
          {
            type: 'message_reaction',
            conversationId,
            messageId,
            userId,
            emoji: null,
            reaction: resultingReaction,
          },
        ],
      });

      return new Response(
        JSON.stringify({ success: true, reacted: false, reaction: resultingReaction }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const reactionId = existing ? existing.id : generateId();
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO message_reactions (id, message_id, conversation_id, user_id, emoji, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(message_id, user_id) DO UPDATE SET emoji = excluded.emoji, updated_at = excluded.updated_at`,
      ).bind(reactionId, messageId, conversationId, userId, emoji, now, now),
      env.DB.prepare(`UPDATE messages SET reaction = ? WHERE id = ?`).bind(emoji, messageId),
    ]);

    await postChatRoomJson(env, conversationId, '/broadcast', {
      events: [
        {
          type: 'message_reaction',
          conversationId,
          messageId,
          userId,
          emoji,
          reaction: emoji,
        },
      ],
    });

    return new Response(
      JSON.stringify({ success: true, reacted: true, reaction: emoji }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  },
);
