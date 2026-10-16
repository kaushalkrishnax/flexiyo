import { IRequest, Router } from 'itty-router';
import { z } from 'zod';
import type { Env, AuthenticatedRequest, MessageRow } from '../types.js';
import { authMiddleware } from '../middleware/auth.js';
import { resolveRequestDevice } from '../middleware/device.js';
import { generateId } from '../utils/crypto.js';
import {
  getMessageEditDenial,
  getMessageSendDenial,
} from '../services/messagePermissions.js';
import { notifyInboxes } from '../services/inbox.js';
import { getConversationForMember } from './conversations.js';

export const messagesRouter = Router({ base: '/api/conversations' });

const devicePayloadSchema = z.object({
  deviceId: z.number().int().positive(),
  ciphertext: z.string().min(1),
  messageType: z.enum(['signal', 'prekey']).optional(),
});

const sendMessageSchema = z
  .object({
    id: z.string().uuid('Message ID must be a UUID'),
    /** Legacy single-ciphertext contract (pre-multi-device clients). */
    encryptedPayload: z.string().min(1).optional(),
    /** Multi-device contract: one ciphertext per target device. */
    payloads: z.array(devicePayloadSchema).min(1).max(10).optional(),
    messageType: z.enum(['signal', 'prekey']),
    recipientId: z.string().uuid('recipientId must be a valid UUID'),
    replyToId: z.string().uuid().nullable().optional(),
  })
  .refine((d) => d.encryptedPayload !== undefined || d.payloads !== undefined, {
    message: 'Either payloads[] (multi-device) or encryptedPayload (legacy) is required',
  });

const editMessageSchema = z
  .object({
    encryptedPayload: z.string().min(1).optional(),
    payloads: z.array(devicePayloadSchema).min(1).max(10).optional(),
    version: z.number().int().positive(),
    messageType: z.enum(['signal', 'prekey']),
  })
  .refine((d) => d.encryptedPayload !== undefined || d.payloads !== undefined, {
    message: 'Either payloads[] or encryptedPayload is required',
  });

const deleteForMeSchema = z.object({
  messageIds: z.array(z.string().uuid()).min(1).max(100),
});

function rowToResponse(row: MessageRow) {
  return {
    id: row.id,
    conversationId: row.conversation_id,
    senderId: row.sender_id,
    // Prefer the ciphertext addressed to the requesting device; fall back to
    // the legacy account-level column for pre-multi-device messages.
    encryptedPayload: row.device_payload ?? row.encrypted_payload,
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
    const limitRaw = parseInt(url.searchParams.get('limit') ?? '50', 10);
    const limit = Math.min(Math.max(1, isNaN(limitRaw) ? 50 : limitRaw), 100);

    const now = Math.floor(Date.now() / 1000);

    // Resolve the requesting device so its per-device ciphertext is returned.
    // Legacy clients without the header fall back to messages.encrypted_payload.
    const requestDevice = await resolveRequestDevice(request, env, userId);
    const myDeviceId = requestDevice?.id ?? -1;

    let rows: D1Result<MessageRow>;

    if (before) {
      // Cursor-based pagination: get messages older than the cursor message
      const cursorMsg = await env.DB.prepare(
        'SELECT created_at FROM messages WHERE id = ? AND conversation_id = ?',
      )
        .bind(before, conversationId)
        .first<{ created_at: number }>();

      if (!cursorMsg) {
        return new Response(JSON.stringify({ error: 'Cursor message not found' }), {
          status: 404,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      rows = await env.DB.prepare(
          `SELECT m.*,
            (SELECT MIN(delivered_at) FROM message_deliveries
             WHERE message_id = m.id) AS delivered_at,
            (SELECT MAX(read_at) FROM message_deliveries
             WHERE message_id = m.id) AS read_at,
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
           AND (m.expires_at IS NULL OR m.expires_at > ?)
           AND m.created_at < ?
         ORDER BY m.created_at DESC
         LIMIT ?`,
      )
        .bind(userId, userId, myDeviceId, conversationId, now, cursorMsg.created_at, limit)
        .all<MessageRow>();
    } else {
      rows = await env.DB.prepare(
          `SELECT m.*,
            (SELECT MIN(delivered_at) FROM message_deliveries
             WHERE message_id = m.id) AS delivered_at,
            (SELECT MAX(read_at) FROM message_deliveries
             WHERE message_id = m.id) AS read_at,
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
           AND (m.expires_at IS NULL OR m.expires_at > ?)
         ORDER BY m.created_at DESC
         LIMIT ?`,
      )
        .bind(userId, userId, myDeviceId, conversationId, now, limit)
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

    const conv = await getConversationForMember(conversationId, userId, env.DB);
    if (!conv) {
      return new Response(JSON.stringify({ error: 'Conversation not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

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

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const parsed = sendMessageSchema.safeParse(body);
    if (!parsed.success) {
      return new Response(
        JSON.stringify({ error: 'Validation failed', details: parsed.error.flatten() }),
        { status: 400, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const { id: msgId, payloads, messageType, recipientId, replyToId } = parsed.data;
    const legacyPayload = parsed.data.encryptedPayload;

    // Validate recipientId is the other conversation participant
    const expectedRecipient =
      conv.user_a_id === userId ? conv.user_b_id : conv.user_a_id;
    if (recipientId !== expectedRecipient) {
      return new Response(JSON.stringify({ error: 'Invalid recipientId' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const now = Math.floor(Date.now() / 1000);

    // Calculate expiry based on conversation's disappearing timer
    const expiresAt =
      conv.disappearing_timer > 0 ? now + conv.disappearing_timer : null;

    const senderDevice = await resolveRequestDevice(request, env, userId);
    const recipientDeviceIds = (
      await env.DB.prepare(
        `SELECT id FROM devices WHERE user_id = ? AND status = 'active' ORDER BY id`,
      )
        .bind(recipientId)
        .all<{ id: number }>()
    ).results.map((r) => r.id);
    const senderOtherDeviceIds = senderDevice
      ? (
          await env.DB.prepare(
            `SELECT id FROM devices WHERE user_id = ? AND status = 'active' AND id <> ?
             ORDER BY id`,
          )
            .bind(userId, senderDevice.id)
            .all<{ id: number }>()
        ).results.map((r) => r.id)
      : [];

    let deliveryRows: Array<{
      deviceId: number;
      payload: string | null;
      messageType: string;
    }> = [];
    let storedLegacyPayload: string | null = null;

    if (payloads && payloads.length > 0) {
      const allowed = new Set([...recipientDeviceIds, ...senderOtherDeviceIds]);
      const addressed = new Set(payloads.map((p) => p.deviceId));
      for (const p of payloads) {
        if (!allowed.has(p.deviceId)) {
          return new Response(
            JSON.stringify({ error: 'unknown_device', deviceId: p.deviceId }),
            { status: 400, headers: { 'Content-Type': 'application/json' } },
          );
        }
      }
      // Every ACTIVE recipient device must receive a ciphertext, otherwise
      // sibling devices could never read the message.
      const missing = recipientDeviceIds.filter((id) => !addressed.has(id));
      if (missing.length > 0) {
        return new Response(
          JSON.stringify({
            error: 'missing_device_payloads',
            missingDeviceIds: missing,
          }),
          { status: 409, headers: { 'Content-Type': 'application/json' } },
        );
      }
      deliveryRows = payloads.map((p) => ({
        deviceId: p.deviceId,
        payload: p.ciphertext,
        messageType: p.messageType ?? messageType,
      }));
      // Degraded path: recipient has no registered devices, so there was
      // nothing to address — keep a ciphertext on the message row so it is
      // not lost (matches pre-multi-device behaviour).
      if (recipientDeviceIds.length === 0) {
        storedLegacyPayload = legacyPayload ?? payloads[0].ciphertext;
      }
    } else {
      // Legacy contract: one ciphertext replicated to every recipient device
      // and mirrored to messages.encrypted_payload for old readers.
      storedLegacyPayload = legacyPayload ?? null;
      deliveryRows = recipientDeviceIds.map((id) => ({
        deviceId: id,
        payload: storedLegacyPayload,
        messageType,
      }));
    }

    // sender_id always from JWT — never from client body
    await env.DB.prepare(
      `INSERT INTO messages
        (id, conversation_id, sender_id, encrypted_payload, message_type, reply_to_id,
         version, is_unsent, created_at, expires_at)
       VALUES (?, ?, ?, ?, ?, ?, 1, 0, ?, ?)`,
    )
      .bind(
        msgId,
        conversationId,
        userId,
        storedLegacyPayload,
        messageType,
        replyToId ?? null,
        now,
        expiresAt,
      )
      .run();

    // Update last_message_at on conversation
    await env.DB.prepare(
      'UPDATE conversations SET last_message_at = ? WHERE id = ?',
    )
      .bind(now, conversationId)
      .run();

    // Per-device delivery ledger. UNIQUE(message_id, recipient_device_id)
    // makes fan-out retries idempotent under retries/races.
    if (deliveryRows.length > 0) {
      const deliveryStmts = deliveryRows.map((row) =>
        env.DB.prepare(
          `INSERT OR IGNORE INTO message_deliveries
             (id, message_id, recipient_device_id, sender_device_id, payload,
              message_type, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)`,
        ).bind(
          generateId(),
          msgId,
          row.deviceId,
          senderDevice?.id ?? null,
          row.payload,
          row.messageType,
          now,
        ),
      );
      await env.DB.batch(deliveryStmts);
    }

    const doId = env.CHAT_ROOM.idFromName(conversationId);
    const stub = env.CHAT_ROOM.get(doId);
    await stub.fetch(
      new Request('https://internal/broadcast', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          type: 'new_message',
          messageId: msgId,
          conversationId,
          senderId: userId,
          senderDeviceId: senderDevice?.id ?? null,
          recipients: [userId, recipientId],
          payloads: deliveryRows.map((r) => ({
            deviceId: r.deviceId,
            payload: r.payload,
            messageType: r.messageType,
          })),
          encryptedPayload: storedLegacyPayload,
          messageType,
          replyToId: replyToId ?? null,
          createdAt: now,
          expiresAt,
        }),
      }),
    );
    await notifyInboxes(env, [userId, recipientId], (targetUserId) => [{
      type: 'inbox_message',
      conversationId,
      senderId: userId,
      // E2EE — the server can never render a real preview.
      preview: 'New message',
      lastMessageAt: now,
      isIncoming: targetUserId !== userId,
    }]);

    return new Response(
      JSON.stringify({
        id: msgId,
        conversationId,
        senderId: userId,
        encryptedPayload: storedLegacyPayload,
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

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    const parsed = deleteForMeSchema.safeParse(body);
    if (!parsed.success) {
      return new Response(JSON.stringify({ error: 'Invalid message IDs' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const messageIds = [...new Set(parsed.data.messageIds)];
    const placeholders = messageIds.map(() => '?').join(', ');
    const matching = await env.DB.prepare(
      `SELECT id FROM messages
       WHERE conversation_id = ? AND id IN (${placeholders})`,
    )
      .bind(conversationId, ...messageIds)
      .all<{ id: string }>();
    if ((matching.results ?? []).length !== messageIds.length) {
      return new Response(JSON.stringify({ error: 'One or more messages were not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const now = Math.floor(Date.now() / 1000);
    await env.DB.batch(messageIds.map((messageId) =>
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
    const conversation = await getConversationForMember(conversationId, userId, env.DB);
    if (!conversation) {
      return new Response(JSON.stringify({ error: 'Conversation not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // Requests and restricted chats do not send seen receipts
    if (conversation.request_status === 'pending') {
      return new Response(JSON.stringify({ read: false, reason: 'pending_request' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // Restriction is per-user: only the CALLER's own flag may suppress their
    // read receipts (the other participant's flag must not leak into this).
    const restrictedCheck = await env.DB.prepare(
      `SELECT 1 FROM conversation_user_settings
       WHERE conversation_id = ? AND user_id = ? AND is_restricted = 1 LIMIT 1`,
    )
      .bind(conversationId, userId)
      .first();

    if (restrictedCheck) {
      return new Response(JSON.stringify({ read: false, reason: 'restricted' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const now = Math.floor(Date.now() / 1000);
    // Reading is an ACCOUNT-level action: mark read (and implied delivered)
    // for every device of this account so sibling devices stay in sync.
    await env.DB.prepare(
      `UPDATE message_deliveries
       SET delivered_at = COALESCE(delivered_at, ?), read_at = ?
       WHERE read_at IS NULL
         AND recipient_device_id IN (SELECT id FROM devices WHERE user_id = ?)
         AND message_id IN (
           SELECT id FROM messages
           WHERE conversation_id = ? AND sender_id != ? AND is_unsent = 0
         )`,
    )
      .bind(now, now, userId, conversationId, userId)
      .run();

    const stub = env.CHAT_ROOM.get(env.CHAT_ROOM.idFromName(conversationId));
    await stub.fetch(new Request('https://internal/broadcast', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        type: 'messages_read',
        conversationId,
        readBy: userId,
        readAt: now,
      }),
    }));

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

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400,
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
    const legacyPayload = parsed.data.encryptedPayload;

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
    const recipientDeviceIds = (
      await env.DB.prepare(
        `SELECT id FROM devices WHERE user_id = ? AND status = 'active' ORDER BY id`,
      )
        .bind(recipientId)
        .all<{ id: number }>()
    ).results.map((r) => r.id);

    let storedLegacyPayload: string | null = legacyPayload ?? null;
    let editRows: Array<{ deviceId: number; payload: string | null; messageType: string }> = [];

    if (payloads && payloads.length > 0) {
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
          recipientDeviceIds.includes(p.deviceId) ||
          (await env.DB.prepare(
            `SELECT 1 AS ok FROM devices
             WHERE id = ? AND user_id = ? AND status = 'active'`,
          )
            .bind(p.deviceId, userId)
            .first());
        if (!belongs) {
          return new Response(
            JSON.stringify({ error: 'unknown_device', deviceId: p.deviceId }),
            { status: 400, headers: { 'Content-Type': 'application/json' } },
          );
        }
      }
      storedLegacyPayload = null; // per-device ciphertexts are now authoritative
      editRows = payloads.map((p) => ({
        deviceId: p.deviceId,
        payload: p.ciphertext,
        messageType: p.messageType ?? messageType,
      }));
    } else {
      // Legacy single-payload edit: refresh every delivery row.
      editRows = recipientDeviceIds.map((id) => ({
        deviceId: id,
        payload: storedLegacyPayload,
        messageType,
      }));
    }

    await env.DB.prepare(
      `UPDATE messages
       SET encrypted_payload = ?, message_type = ?, version = ?, edited_at = ?
       WHERE id = ?`,
    )
      .bind(storedLegacyPayload, messageType, newVersion, now, messageId)
      .run();

    if (legacyPayload !== undefined) {
      // Legacy edit path: one ciphertext overwrites all device rows.
      await env.DB.prepare(
        `UPDATE message_deliveries SET payload = ?, message_type = ?
         WHERE message_id = ?`,
      )
        .bind(legacyPayload, messageType, messageId)
        .run();
    } else if (editRows.length > 0) {
      await env.DB.batch(
        editRows.map((row) =>
          env.DB.prepare(
            `UPDATE message_deliveries SET payload = ?, message_type = ?
             WHERE message_id = ? AND recipient_device_id = ?`,
          ).bind(row.payload, row.messageType, messageId, row.deviceId),
        ),
      );
    }

    const doId = env.CHAT_ROOM.idFromName(conversationId);
    const stub = env.CHAT_ROOM.get(doId);
    await stub.fetch(
      new Request('https://internal/broadcast', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          type: 'message_edited',
          messageId,
          conversationId,
          recipients: [userId, recipientId],
          payloads: editRows.map((r) => ({
            deviceId: r.deviceId,
            payload: r.payload,
            messageType: r.messageType,
          })),
          encryptedPayload: storedLegacyPayload,
          messageType,
          version: newVersion,
          editedAt: now,
        }),
      }),
    );
    return new Response(
      JSON.stringify({
        id: messageId,
        conversationId,
        senderId: userId,
        encryptedPayload: storedLegacyPayload,
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

    if (message.is_unsent === 1) {
      return new Response(JSON.stringify({ deleted: true, scope: 'global' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // Mark as unsent; clear payload everywhere to prevent payload leakage
    await env.DB.prepare(
      `UPDATE messages SET is_unsent = 1, encrypted_payload = NULL WHERE id = ?`,
    )
      .bind(messageId)
      .run();
    await env.DB.prepare(
      `UPDATE message_deliveries SET payload = NULL WHERE message_id = ?`,
    )
      .bind(messageId)
      .run();

    const doId = env.CHAT_ROOM.idFromName(conversationId);
    const stub = env.CHAT_ROOM.get(doId);
    await stub.fetch(
      new Request('https://internal/broadcast', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          type: 'message_unsent',
          messageId,
          conversationId,
          unsentAt: now,
        }),
      }),
    );

    // Keep the other participant's chat-list preview in sync ("Message unsent").
    const otherParticipant = conv.user_a_id === userId ? conv.user_b_id : conv.user_a_id;
    await notifyInboxes(env, [otherParticipant], () => [{
      type: 'message_unsent',
      conversationId,
      messageId,
    }]);

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

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

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
            type: 'message_reaction',
            conversationId,
            messageId,
            userId,
            emoji: null,
            reaction: resultingReaction,
          }),
        }),
      );

      return new Response(
        JSON.stringify({ success: true, reacted: false, reaction: resultingReaction }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const reactionId = existing ? existing.id : generateId();
    await env.DB.prepare(
      `INSERT INTO message_reactions (id, message_id, conversation_id, user_id, emoji, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(message_id, user_id) DO UPDATE SET emoji = excluded.emoji, updated_at = excluded.updated_at`,
    )
      .bind(reactionId, messageId, conversationId, userId, emoji, now, now)
      .run();

    await env.DB.prepare(`UPDATE messages SET reaction = ? WHERE id = ?`)
      .bind(emoji, messageId)
      .run();

    const doId = env.CHAT_ROOM.idFromName(conversationId);
    const stub = env.CHAT_ROOM.get(doId);
    await stub.fetch(
      new Request('https://internal/broadcast', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          type: 'message_reaction',
          conversationId,
          messageId,
          userId,
          emoji,
          reaction: emoji,
        }),
      }),
    );

    return new Response(
      JSON.stringify({ success: true, reacted: true, reaction: emoji }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  },
);

