import { IRequest, Router } from 'itty-router';
import { z } from 'zod';
import type { Env, AuthenticatedRequest, MessageRow } from '../types.js';
import { authMiddleware } from '../middleware/auth.js';
import { INSTALLATION_HEADER, pairedActiveDeviceIds, resolveRequestDevice } from '../middleware/device.js';
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
import { runBatched } from '../utils/d1.js';
import { validateConversationEnvelope } from '../services/conversationKeys.js';

export const messagesRouter = Router({ base: '/api/conversations' });

const MAX_CIPHERTEXT_CHARS = 64 * 1024;

const devicePayloadSchema = z.object({
  deviceId: z.number().int().positive(),
  ciphertext: z.string().min(1).max(MAX_CIPHERTEXT_CHARS),
  messageType: z.enum(['signal', 'prekey']).optional(),
});

const sendMessageSchema = z.object({
  id: z.string().uuid('Message ID must be a UUID'),
  payloads: z.array(devicePayloadSchema).min(1).max(10),
  messageType: z.enum(['signal', 'prekey']),
  recipientId: z.string().uuid('recipientId must be a valid UUID'),
  mediaId: z.string().uuid('mediaId must be a valid UUID').nullable().optional(),
  replyToId: z.string().uuid().nullable().optional(),
});

const editMessageSchema = z
  .object({
    payloads: z.array(devicePayloadSchema).min(1).max(10),
    version: z.number().int().positive(),
    messageType: z.enum(['signal', 'prekey']),
  });

const conversationKeyMessageSchema = z.object({
  encryptionVersion: z.literal(2),
  id: z.string().uuid(),
  ciphertext: z.string().min(1).max(MAX_CIPHERTEXT_CHARS),
  nonce: z.string().min(1).max(128),
  authTag: z.string().min(1).max(128),
  keyEpoch: z.number().int().positive(),
  recipientId: z.string().uuid(),
  mediaId: z.string().uuid().nullable().optional(),
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

function rowToResponse(row: MessageRow) {
  return {
    id: row.id,
    conversationId: row.conversation_id,
    senderId: row.sender_id,
    senderDeviceId: row.sender_device_id ?? null,
    encryptedPayload: row.encryption_version === 2 ? row.ciphertext ?? null : row.device_payload,
    encryptionVersion: row.encryption_version ?? 1,
    ciphertext: row.ciphertext ?? null,
    nonce: row.nonce ?? null,
    authTag: row.auth_tag ?? null,
    keyEpoch: row.key_epoch ?? null,
    messageType: row.device_message_type ?? row.message_type,
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

    const url = new URL(request.url);
    const before = url.searchParams.get('before');
    const beforeCreatedAtRaw = url.searchParams.get('beforeCreatedAt');
    const beforeCreatedAtValue = beforeCreatedAtRaw == null
      ? null
      : Number.parseInt(beforeCreatedAtRaw, 10);
    const beforeCreatedAt = Number.isFinite(beforeCreatedAtValue)
      ? beforeCreatedAtValue
      : null;
    const afterRaw = url.searchParams.get('after');
    const afterValue = afterRaw == null ? null : Number.parseInt(afterRaw, 10);
    const after = Number.isFinite(afterValue) ? afterValue : null;
    const limitRaw = parseInt(url.searchParams.get('limit') ?? '50', 10);
    const limit = Math.min(Math.max(1, isNaN(limitRaw) ? 50 : limitRaw), 100);

    const now = Math.floor(Date.now() / 1000);

    // Resolve the requesting device so only its ciphertext is returned.
    const requestDevice = await resolveRequestDevice(request, env, userId);
    if (!requestDevice) {
      return new Response(JSON.stringify({ error: 'Device registration required' }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    const myDeviceId = requestDevice.id;

    let rows: D1Result<MessageRow>;

    if (before) {
      // Cursor-based pagination: get messages older than the cursor message.
      // The cursor row may have expired or been deleted since the client
      // loaded it, so accept the client's copy of its timestamp as a fallback.
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
      // Without the row, the id tie-break could skip same-second messages whose
      // id sorts after the deleted cursor. Prefer overlapping the boundary (the
      // client de-duplicates by id) over leaving a permanent gap.
      const includeCursorSecond = cursorMsg == null ? 1 : 0;

      rows = await env.DB.prepare(
          `SELECT m.*,
            COALESCE(m.delivered_at, (
              SELECT MIN(md.delivered_at) FROM message_deliveries md
              WHERE md.message_id = m.id
            )) AS delivered_at,
            COALESCE(m.read_at, (
              SELECT MAX(md.read_at) FROM message_deliveries md
              WHERE md.message_id = m.id
            )) AS read_at,
            myd.payload AS device_payload,
            myd.message_type AS device_message_type,
            (m.sender_id = ?) AS is_sent_by_me
         FROM messages m
         LEFT JOIN local_deletions ld
           ON ld.message_id = m.id AND ld.user_id = ?
         LEFT JOIN message_deliveries myd
           ON myd.message_id = m.id AND myd.recipient_device_id = ?
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
          myDeviceId,
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
            COALESCE(m.delivered_at, (
              SELECT MIN(md.delivered_at) FROM message_deliveries md
              WHERE md.message_id = m.id
            )) AS delivered_at,
            COALESCE(m.read_at, (
              SELECT MAX(md.read_at) FROM message_deliveries md
              WHERE md.message_id = m.id
            )) AS read_at,
            myd.payload AS device_payload,
            myd.message_type AS device_message_type,
            (m.sender_id = ?) AS is_sent_by_me
         FROM messages m
         LEFT JOIN local_deletions ld
           ON ld.message_id = m.id AND ld.user_id = ?
         LEFT JOIN message_deliveries myd
           ON myd.message_id = m.id AND myd.recipient_device_id = ?
         WHERE m.conversation_id = ?
           AND ld.id IS NULL
           AND m.is_unsent = 0
           AND m.message_type != 'system'
           AND (m.expires_at IS NULL OR m.expires_at > ?)
           AND (? IS NULL OR m.created_at >= ?)
         ORDER BY m.created_at DESC, m.id DESC
         LIMIT ?`,
      )
        .bind(userId, userId, myDeviceId, conversationId, now, after, after, limit)
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

    // Restriction is the caller's own flag; either participant may have blocked
    // the other. Membership and block state come from the same read.
    const expectedRecipient =
      conv.user_a_id === userId ? conv.user_b_id : conv.user_a_id;

    let hasExistingMessage = false;
    if (conv.request_status === 'pending' && conv.initiated_by_id === userId) {
      const existingMessage = await env.DB.prepare(
        'SELECT id FROM messages WHERE conversation_id = ? LIMIT 1',
      )
        .bind(conversationId)
        .first<{ id: string }>();
      hasExistingMessage = existingMessage != null;
    }

    const sendDenial = getMessageSendDenial({
      requestStatus: conv.request_status,
      initiatedById: conv.initiated_by_id,
      userId,
      hasExistingMessage,
      isBlocked: conv.is_blocked === 1,
    });
    if (sendDenial === 'rejected_request' ||
        sendDenial === 'recipient_has_not_accepted') {
      return new Response(JSON.stringify({ error: 'Accept the message request before replying' }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    if (sendDenial === 'initial_request_already_sent') {
      return new Response(JSON.stringify({ error: 'Wait for the recipient to accept your request' }), {
        status: 409,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    if (sendDenial === 'blocked_chat') {
      return new Response(JSON.stringify({ error: "You can't message this account" }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const bodyResult = await readJsonBody(request);
    if (!bodyResult.ok) return bodyResult.response;
    const body = bodyResult.body;

    if (typeof body === 'object' && body !== null &&
        (body as Record<string, unknown>).encryptionVersion === 2) {
      const v2Parsed = conversationKeyMessageSchema.safeParse(body);
      if (!v2Parsed.success) {
        return new Response(
          JSON.stringify({ error: 'Validation failed', details: v2Parsed.error.flatten() }),
          { status: 400, headers: { 'Content-Type': 'application/json' } },
        );
      }
      const envelope = validateConversationEnvelope(v2Parsed.data as unknown as Record<string, unknown>);
      if (!envelope.ok) return new Response(JSON.stringify({ error: envelope.error }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });

      const v2 = v2Parsed.data;
      if (v2.recipientId !== expectedRecipient) {
        return new Response(JSON.stringify({ error: 'Invalid recipientId' }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      const device = await resolveRequestDevice(request, env, userId);
      if (!device || device.status !== 'active' || device.encryption_version !== 2 ||
          !device.identity_public_key) {
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
              WHERE user_id IN (?, ?) AND status = 'active' AND encryption_version = 2) AS active_count,
             (SELECT COUNT(*) FROM devices
              WHERE user_id = ? AND status = 'active' AND encryption_version = 2) AS sender_count,
             (SELECT COUNT(*) FROM devices
              WHERE user_id = ? AND status = 'active' AND encryption_version = 2) AS recipient_count,
             (SELECT COUNT(*) FROM device_key_envelopes e
              JOIN devices d ON d.id = e.recipient_device_id
              WHERE e.conversation_id = ? AND e.epoch = ?
                AND d.user_id IN (?, ?) AND d.status = 'active'
                AND d.encryption_version = 2) AS envelope_count`,
        ).bind(
          userId, expectedRecipient, userId, expectedRecipient,
          conversationId, v2.keyEpoch, userId, expectedRecipient,
        ),
      ]);

      const existingMessage = existingResult.results?.[0] as
        { id: string; sender_id: string; conversation_id: string } | undefined;
      if (existingMessage) {
        if (existingMessage.sender_id !== userId || existingMessage.conversation_id !== conversationId) {
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
        return new Response(JSON.stringify({
          error: 'key_epoch_conflict',
          currentEpoch: conv.key_epoch,
        }), { status: 409, headers: { 'Content-Type': 'application/json' } });
      }

      const coverage = coverageResult.results?.[0] as
        { active_count: number; sender_count: number; recipient_count: number; envelope_count: number } | undefined;
      if (!coverage || coverage.sender_count < 1 || coverage.recipient_count < 1 ||
          coverage.active_count !== coverage.envelope_count) {
        return new Response(JSON.stringify({ error: 'conversation_keys_not_provisioned' }), {
          status: 409,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      const now = Math.floor(Date.now() / 1000);
      // Disappearing timers start when the recipient reads the message, matching
      // the legacy v1 path. The read endpoint stamps expires_at below.
      const expiresAt = null;
      try {
        await env.DB.batch([
          env.DB.prepare(
            `INSERT INTO messages
               (id, conversation_id, sender_id, sender_device_id, message_type,
                reply_to_id, media_id, version, is_unsent, created_at, expires_at,
                ciphertext, nonce, auth_tag, key_epoch, encryption_version)
             VALUES (?, ?, ?, ?, 'signal', ?, ?, 1, 0, ?, ?, ?, ?, ?, ?, 2)`,
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
            'UPDATE conversations SET last_message_at = ? WHERE id = ?',
          ).bind(now, conversationId),
          ...(v2.mediaId ? [
            env.DB.prepare(
              'UPDATE media SET consumed = 1 WHERE id = ? AND conversation_id = ? AND sender_id = ?',
            ).bind(v2.mediaId, conversationId, userId),
          ] : []),
        ]);
      } catch {
        const duplicate = await env.DB.prepare(
          'SELECT sender_id, conversation_id FROM messages WHERE id = ?',
        ).bind(v2.id).first<{ sender_id: string; conversation_id: string }>();
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
      const stub = env.CHAT_ROOM.get(env.CHAT_ROOM.idFromName(conversationId));
      await stub.fetch(new Request('https://internal/broadcast', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ events: [event] }),
      }));

      const activeUsers = await notifyInboxes(env, [userId, expectedRecipient], (targetUserId) => [{
        type: 'inbox_message',
        conversationId,
        senderId: userId,
        preview: 'New message',
        lastMessageAt: now,
        isIncoming: targetUserId !== userId,
      }]);
      await sendMessagePush(env, {
        senderId: userId,
        recipientId: expectedRecipient,
        conversationId,
        recipientHasActiveSocket: activeUsers.has(expectedRecipient),
      });

      return new Response(JSON.stringify({
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
      }), { status: 201, headers: { 'Content-Type': 'application/json' } });
    }

    const parsed = sendMessageSchema.safeParse(body);
    if (!parsed.success) {
      return new Response(
        JSON.stringify({ error: 'Validation failed', details: parsed.error.flatten() }),
        { status: 400, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const { id: msgId, payloads, messageType, recipientId, replyToId, mediaId } = parsed.data;

    // Validate recipientId is the other conversation participant
    if (recipientId !== expectedRecipient) {
      return new Response(JSON.stringify({ error: 'Invalid recipientId' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // Media ownership, idempotency and device state are independent reads —
    // one round trip instead of three sequential ones.
    const installationId = request.headers.get(INSTALLATION_HEADER);
    const [media, existingMessage, deviceRows] = await Promise.all([
      mediaId != null
        ? env.DB.prepare(
            `SELECT id FROM media
             WHERE id = ? AND conversation_id = ? AND sender_id = ? AND consumed = 0`,
          )
            .bind(mediaId, conversationId, userId)
            .first<{ id: string }>()
        : Promise.resolve(null),
      env.DB.prepare(
        `SELECT id, sender_id, conversation_id FROM messages WHERE id = ?`,
      )
        .bind(msgId)
        .first<{ id: string; sender_id: string; conversation_id: string }>(),
      // The caller's own installation may be inactive and still send; the
      // recipient's devices must be active.
      installationId
        ? env.DB.prepare(
            `SELECT id, user_id FROM devices
             WHERE (user_id = ? AND installation_id = ? AND encryption_version = 1)
                OR (user_id = ? AND status = 'active' AND encryption_version = 1)
             ORDER BY id`,
          )
            .bind(userId, installationId, recipientId)
            .all<{ id: number; user_id: string }>()
        : Promise.resolve(null),
    ]);

    if (existingMessage) {
      // Idempotent retry: the message was already committed. Do not duplicate
      // side effects; return the existing committed result. This check runs
      // before media validation so a retried send still succeeds after the
      // media was consumed.
      if (
        existingMessage.sender_id !== userId ||
        existingMessage.conversation_id !== conversationId
      ) {
        return new Response(JSON.stringify({ error: 'Message id conflict' }), {
          status: 409,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      return new Response(
        JSON.stringify({ id: msgId, status: 'already_committed' }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    }

    if (mediaId != null && !media) {
      return new Response(JSON.stringify({ error: 'Invalid mediaId' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const now = Math.floor(Date.now() / 1000);
    // Disappearing-message timers start when a recipient reads the message.
    const expiresAt = null;

    const senderDeviceId = (deviceRows?.results ?? []).find((row) => row.user_id === userId)?.id;
    if (!senderDeviceId) {
      return new Response(JSON.stringify({ error: 'Device registration required' }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const recipientDeviceIds = (deviceRows?.results ?? [])
      .filter((row) => row.user_id === recipientId)
      .map((row) => row.id);
    if (recipientDeviceIds.length === 0) {
      return new Response(
        JSON.stringify({ error: "Recipient hasn't registered encryption keys yet." }),
        { status: 409, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const deliveryRows = payloads.map((p) => ({
      deviceId: p.deviceId,
      payload: p.ciphertext,
      messageType: p.messageType ?? messageType,
    }));
    for (const p of payloads) {
      if (!recipientDeviceIds.includes(p.deviceId)) {
        return new Response(
          JSON.stringify({ error: 'unknown_device', deviceId: p.deviceId }),
          { status: 400, headers: { 'Content-Type': 'application/json' } },
        );
      }
    }
    // Every active recipient device must receive a ciphertext, otherwise a
    // device silently misses the message.
    const missing = recipientDeviceIds.filter(
      (id) => !deliveryRows.some((r) => r.deviceId === id),
    );
    if (missing.length > 0) {
      return new Response(
        JSON.stringify({
          error: 'missing_device_payloads',
          missingDeviceIds: missing,
        }),
        { status: 409, headers: { 'Content-Type': 'application/json' } },
      );
    }

    // One transaction: the message row, the conversation timestamp and the
    // per-device ciphertexts commit together or not at all, so a failed write
    // cannot leave a message that a retry would treat as already delivered.
    await env.DB.batch([
      // sender_id always from JWT — never from client body
      env.DB.prepare(
        `INSERT INTO messages
          (id, conversation_id, sender_id, sender_device_id, message_type, reply_to_id,
           media_id, version, is_unsent, created_at, expires_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?)`,
      ).bind(
        msgId,
        conversationId,
        userId,
        senderDeviceId,
        messageType,
        replyToId ?? null,
        mediaId ?? null,
        now,
        expiresAt,
      ),

      env.DB.prepare(
        'UPDATE conversations SET last_message_at = ? WHERE id = ?',
      ).bind(now, conversationId),

      // Per-device delivery ledger. UNIQUE(message_id, recipient_device_id)
      // makes fan-out retries idempotent under retries/races.
      ...deliveryRows.map((row) =>
        env.DB.prepare(
          `INSERT OR IGNORE INTO message_deliveries
             (id, message_id, recipient_device_id, sender_device_id, payload,
              message_type, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)`,
        ).bind(generateId(), msgId, row.deviceId, senderDeviceId, row.payload, row.messageType, now),
      ),
    ]);

    const doId = env.CHAT_ROOM.idFromName(conversationId);
    const stub = env.CHAT_ROOM.get(doId);
    await stub.fetch(
      new Request('https://internal/broadcast', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          events: [{
            type: 'new_message',
            messageId: msgId,
            conversationId,
            senderId: userId,
            senderDeviceId,
            recipients: [userId, recipientId],
            payloads: deliveryRows.map((r) => ({
              deviceId: r.deviceId,
              payload: r.payload,
              messageType: r.messageType,
            })),
            messageType,
            replyToId: replyToId ?? null,
            createdAt: now,
            expiresAt,
          }],
        }),
      }),
    );
    const activeUsers = await notifyInboxes(env, [userId, recipientId], (targetUserId) => [{
      type: 'inbox_message',
      conversationId,
      senderId: userId,
      // E2EE — the server can never render a real preview.
      preview: 'New message',
      lastMessageAt: now,
      isIncoming: targetUserId !== userId,
    }]);

    // Best-effort FCM push so a backgrounded/offline recipient still learns
    // about the message. Restricted and muted chats never notify. Failures
    // never affect delivery.
    await sendMessagePush(env, {
      senderId: userId,
      recipientId,
      conversationId,
      recipientHasActiveSocket: activeUsers.has(recipientId),
    });

    return new Response(
      JSON.stringify({
        id: msgId,
        conversationId,
        senderId: userId,
        senderDeviceId,
        encryptedPayload: deliveryRows.find((r) => r.deviceId === senderDeviceId)?.payload ?? null,
        messageType,
        replyToId: replyToId ?? null,
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
    const body = bodyResult.body;
    const parsed = deleteForMeSchema.safeParse(body);
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
    await runBatched(env.DB, messageIds.map((messageId) =>
      env.DB.prepare(
        `INSERT OR IGNORE INTO local_deletions (id, user_id, message_id, deleted_at)
         VALUES (?, ?, ?, ?)`,
      ).bind(generateId(), userId, messageId, now),
    ));

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

    // Requests and blocked chats do not send seen receipts
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

    // Batched so the newly-read id set comes from the pre-update state and the
    // flip commits in the same round trip.
    const [legacyUnread, v2Unread] = await env.DB.batch<{ id: string }>([
      env.DB.prepare(
        `SELECT DISTINCT m.id
         FROM messages m
         JOIN message_deliveries md ON md.message_id = m.id
         WHERE m.conversation_id = ? AND m.sender_id != ? AND m.is_unsent = 0
           AND m.encryption_version = 1 AND md.read_at IS NULL
           AND md.recipient_device_id IN (SELECT id FROM devices WHERE user_id = ?)`,
      ).bind(conversationId, userId, userId),
      env.DB.prepare(
        `SELECT id FROM messages
         WHERE conversation_id = ? AND sender_id != ? AND is_unsent = 0
           AND encryption_version = 2 AND read_at IS NULL`,
      ).bind(conversationId, userId),
      env.DB.prepare(
        `WITH target_messages AS MATERIALIZED (
           SELECT id FROM messages
           WHERE conversation_id = ? AND sender_id != ?
             AND is_unsent = 0 AND encryption_version = 1
         )
         UPDATE message_deliveries
         SET delivered_at = COALESCE(delivered_at, ?), read_at = ?
         WHERE read_at IS NULL
           AND recipient_device_id IN (SELECT id FROM devices WHERE user_id = ?)
           AND message_id IN (SELECT id FROM target_messages)`,
      ).bind(conversationId, userId, now, now, userId),
      env.DB.prepare(
        `UPDATE messages SET delivered_at = COALESCE(delivered_at, ?), read_at = ?
         WHERE conversation_id = ? AND sender_id != ? AND is_unsent = 0
           AND encryption_version = 2 AND read_at IS NULL`,
      ).bind(now, now, conversationId, userId),
    ]);

    const newlyReadMessageIds = [
      ...(legacyUnread.results ?? []).map((row) => row.id),
      ...(v2Unread.results ?? []).map((row) => row.id),
    ];

    if (newlyReadMessageIds.length > 0) {
      const stub = env.CHAT_ROOM.get(env.CHAT_ROOM.idFromName(conversationId));
      await stub.fetch(new Request('https://internal/broadcast', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          events: [{
            type: 'messages_read',
            conversationId,
            readBy: userId,
            readAt: now,
          }],
        }),
      }));

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

      await notifyInboxes(env, [userId], () => [{
        type: 'unread_reset',
        conversationId,
      }]);
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
    const body = bodyResult.body;

    if (typeof body === 'object' && body !== null &&
        (body as Record<string, unknown>).encryptionVersion === 2) {
      const parsedV2 = conversationKeyEditSchema.safeParse(body);
      if (!parsedV2.success) {
        return new Response(
          JSON.stringify({ error: 'Validation failed', details: parsedV2.error.flatten() }),
          { status: 400, headers: { 'Content-Type': 'application/json' } },
        );
      }
      if (message.encryption_version !== 2) {
        return new Response(JSON.stringify({ error: 'Cannot change encryption version of an existing message' }), {
          status: 409,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      const envelope = validateConversationEnvelope(parsedV2.data as unknown as Record<string, unknown>);
      if (!envelope.ok) {
        return new Response(JSON.stringify({ error: envelope.error }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      if (message.version !== parsedV2.data.version) {
        return new Response(JSON.stringify({
          error: 'Conflict: message has been modified. Fetch latest and retry.',
          currentVersion: message.version,
        }), { status: 409, headers: { 'Content-Type': 'application/json' } });
      }
      const device = await resolveRequestDevice(request, env, userId);
      if (!device || device.status !== 'active' || device.encryption_version !== 2) {
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
        return new Response(JSON.stringify({
          error: 'key_epoch_conflict',
          currentEpoch: conv.key_epoch,
        }), { status: 409, headers: { 'Content-Type': 'application/json' } });
      }

      const nextVersion = parsedV2.data.version + 1;
      const updated = await env.DB.prepare(
        `UPDATE messages
         SET ciphertext = ?, nonce = ?, auth_tag = ?, key_epoch = ?,
             version = ?, edited_at = ?
         WHERE id = ? AND conversation_id = ? AND sender_id = ?
           AND encryption_version = 2 AND version = ?`,
      ).bind(
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
      ).run();
      if ((updated.meta.changes ?? 0) !== 1) {
        return new Response(JSON.stringify({ error: 'message_version_conflict' }), {
          status: 409,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      const recipientId = conv.user_a_id === userId ? conv.user_b_id : conv.user_a_id;
      const stub = env.CHAT_ROOM.get(env.CHAT_ROOM.idFromName(conversationId));
      await stub.fetch(new Request('https://internal/broadcast', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          events: [{
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
          }],
        }),
      }));

      return new Response(JSON.stringify({
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
      }), { status: 200, headers: { 'Content-Type': 'application/json' } });
    }

    if (message.encryption_version === 2) {
      return new Response(JSON.stringify({ error: 'A version 2 encrypted edit is required' }), {
        status: 409,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const parsed = editMessageSchema.safeParse(body);
    if (!parsed.success) {
      return new Response(
        JSON.stringify({ error: 'Validation failed', details: parsed.error.flatten() }),
        { status: 400, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const { payloads, version, messageType } = parsed.data;

    // Optimistic concurrency: reject if stored version != client's version
    if (message.version !== version) {
      return new Response(
        JSON.stringify({
          error: 'Conflict: message has been modified. Fetch latest and retry.',
          currentVersion: message.version,
        }),
        { status: 409, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const newVersion = version + 1;

    const recipientId = conv.user_a_id === userId ? conv.user_b_id : conv.user_a_id;
    // Sender and recipient device sets in one round trip: the ownership check
    // below must not issue a query per payload.
    const editDevices = await pairedActiveDeviceIds(env.DB, userId, recipientId);
    const recipientDeviceIds = editDevices.peer;

    const editRows: Array<{ deviceId: number; payload: string; messageType: string }> =
      payloads.map((p) => ({
        deviceId: p.deviceId,
        payload: p.ciphertext,
        messageType: p.messageType ?? messageType,
      }));

    const addressed = new Set(payloads.map((p) => p.deviceId));
    const missing = recipientDeviceIds.filter((id) => !addressed.has(id));
    if (missing.length > 0) {
      return new Response(
        JSON.stringify({ error: 'missing_device_payloads', missingDeviceIds: missing }),
        { status: 409, headers: { 'Content-Type': 'application/json' } },
      );
    }
    for (const p of payloads) {
      const belongs =
        recipientDeviceIds.includes(p.deviceId) || editDevices.own.includes(p.deviceId);
      if (!belongs) {
        return new Response(
          JSON.stringify({ error: 'unknown_device', deviceId: p.deviceId }),
          { status: 400, headers: { 'Content-Type': 'application/json' } },
        );
      }
    }

    // Version bump and per-device ciphertext replacement commit together.
    await env.DB.batch([
      env.DB.prepare(
        `UPDATE messages SET message_type = ?, version = ?, edited_at = ? WHERE id = ?`,
      ).bind(messageType, newVersion, now, messageId),

      ...editRows.map((row) =>
        env.DB.prepare(
          `UPDATE message_deliveries SET payload = ?, message_type = ?
           WHERE message_id = ? AND recipient_device_id = ?`,
        ).bind(row.payload, row.messageType, messageId, row.deviceId),
      ),
    ]);

    const doId = env.CHAT_ROOM.idFromName(conversationId);
    const stub = env.CHAT_ROOM.get(doId);
    await stub.fetch(
      new Request('https://internal/broadcast', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          events: [{
            type: 'message_edited',
            messageId,
            conversationId,
            recipients: [userId, recipientId],
            payloads: editRows.map((r) => ({
              deviceId: r.deviceId,
              payload: r.payload,
              messageType: r.messageType,
            })),
            messageType,
            version: newVersion,
            editedAt: now,
          }],
        }),
      }),
    );
    return new Response(
      JSON.stringify({
        id: messageId,
        conversationId,
        senderId: userId,
        encryptedPayload: editRows.find((r) => r.deviceId === message.sender_device_id)?.payload ?? null,
        messageType,
        version: newVersion,
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
      // Local deletion — only visible to this user
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

    // Unsend (global) — only the original sender may do this
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

const reactionSchema = z.object({
  emoji: z.string().min(1).max(10),
});

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
    const body = bodyResult.body;

    const parsed = reactionSchema.safeParse(body);
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
      // Toggle off: remove user's reaction
      await env.DB.prepare(
        `DELETE FROM message_reactions WHERE id = ?`,
      )
        .bind(existing.id)
        .run();

      // Find any other reaction on this message (most recently updated)
      const otherReaction = await env.DB.prepare(
        `SELECT emoji FROM message_reactions WHERE message_id = ? ORDER BY updated_at DESC LIMIT 1`,
      )
        .bind(messageId)
        .first<{ emoji: string }>();

      resultingReaction = otherReaction?.emoji ?? null;
      await env.DB.prepare(`UPDATE messages SET reaction = ? WHERE id = ?`)
        .bind(resultingReaction, messageId)
        .run();

      const doId = env.CHAT_ROOM.idFromName(conversationId);
      const stub = env.CHAT_ROOM.get(doId);
      await stub.fetch(
        new Request('https://internal/broadcast', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            events: [{
              type: 'message_reaction',
              conversationId,
              messageId,
              userId,
              emoji: null,
              reaction: resultingReaction,
            }],
          }),
        }),
      );

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

      env.DB.prepare(`UPDATE messages SET reaction = ? WHERE id = ?`)
        .bind(emoji, messageId),
    ]);

    const doId = env.CHAT_ROOM.idFromName(conversationId);
    const stub = env.CHAT_ROOM.get(doId);
    await stub.fetch(
      new Request('https://internal/broadcast', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          events: [{
            type: 'message_reaction',
            conversationId,
            messageId,
            userId,
            emoji,
            reaction: emoji,
          }],
        }),
      }),
    );

    return new Response(
      JSON.stringify({ success: true, reacted: true, reaction: emoji }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  },
);
