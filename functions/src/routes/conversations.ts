import { IRequest, Router } from 'itty-router';
import { z } from 'zod';
import type {
  Env,
  AuthenticatedRequest,
  ConversationRow,
} from '../types.js';
import { authMiddleware } from '../middleware/auth.js';
import { generateId } from '../utils/crypto.js';

export const conversationsRouter = Router({ base: '/api/conversations' });

const createConversationSchema = z.object({
  participantId: z.string().uuid('participantId must be a valid UUID'),
});
const requestDecisionSchema = z.object({
  action: z.enum(['accept', 'reject']),
});

const VALID_TIMERS = [0, 30, 60, 300, 3600, 86400, 604800] as const;
const disappearingTimerSchema = z.object({
  timer: z.union([
    z.literal(0),
    z.literal(30),
    z.literal(60),
    z.literal(300),
    z.literal(3600),
    z.literal(86400),
    z.literal(604800),
  ]),
});

async function getConversationForMember(
  conversationId: string,
  userId: string,
  db: D1Database,
): Promise<ConversationRow | null> {
  const conv = await db
    .prepare(
      `SELECT * FROM conversations WHERE id = ?
       AND (user_a_id = ? OR user_b_id = ?)`,
    )
    .bind(conversationId, userId, userId)
    .first<ConversationRow>();
  return conv ?? null;
}

conversationsRouter.post(
  '/',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const parsed = createConversationSchema.safeParse(body);
    if (!parsed.success) {
      return new Response(
        JSON.stringify({ error: 'Validation failed', details: parsed.error.flatten() }),
        { status: 400, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const { participantId } = parsed.data;

    if (participantId === userId) {
      return new Response(JSON.stringify({ error: 'Cannot start a conversation with yourself' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // Check participant exists
    const participant = await env.DB.prepare(
      'SELECT id, username FROM users WHERE id = ?',
    )
      .bind(participantId)
      .first<{ id: string; username: string }>();

    if (!participant) {
      return new Response(JSON.stringify({ error: 'Participant user not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // Enforce canonical ordering so UNIQUE(user_a_id, user_b_id) prevents duplicates
    const [userA, userB] =
      userId < participantId ? [userId, participantId] : [participantId, userId];

    // Check if conversation already exists
    const existing = await env.DB.prepare(
      'SELECT * FROM conversations WHERE user_a_id = ? AND user_b_id = ?',
    )
      .bind(userA, userB)
      .first<ConversationRow>();

    if (existing) {
      if (existing.request_status === 'rejected') {
        return new Response(JSON.stringify({ error: 'This message request was rejected' }), {
          status: 403,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      const conversant =
        existing.user_a_id === userId
          ? { id: existing.user_b_id, username: participant.username }
          : { id: existing.user_a_id, username: participant.username };

      return new Response(
        JSON.stringify({
          id: existing.id,
          conversant,
          disappearingTimer: existing.disappearing_timer,
          requestStatus: existing.request_status,
          initiatedById: existing.initiated_by_id,
          lastMessageAt: existing.last_message_at,
          unreadCount: 0,
          createdAt: existing.created_at,
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const convId = generateId();
    const now = Math.floor(Date.now() / 1000);

    await env.DB.prepare(
      `INSERT INTO conversations
         (id, user_a_id, user_b_id, initiated_by_id, request_status, disappearing_timer, created_at)
       VALUES (?, ?, ?, ?, 'pending', 0, ?)`,
    )
      .bind(convId, userA, userB, userId, now)
      .run();

    // Fetch the requesting user's username for context
    const myUser = await env.DB.prepare('SELECT username FROM users WHERE id = ?')
      .bind(userId)
      .first<{ username: string }>();

    return new Response(
      JSON.stringify({
        id: convId,
        conversant: { id: participant.id, username: participant.username },
        disappearingTimer: 0,
        requestStatus: 'pending',
        initiatedById: userId,
        lastMessageAt: null,
        unreadCount: 0,
        createdAt: now,
        myUsername: myUser?.username,
      }),
      { status: 201, headers: { 'Content-Type': 'application/json' } },
    );
  },
);

conversationsRouter.get(
  '/requests',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const rows = await env.DB.prepare(
      `SELECT c.id, c.disappearing_timer, c.created_at, c.last_message_at,
         c.request_status, c.initiated_by_id,
         COALESCE(cus.is_restricted, 0) AS is_restricted,
         (SELECT COUNT(*) FROM message_deliveries md
          JOIN messages m ON m.id = md.message_id
          WHERE md.recipient_device_id IN (SELECT id FROM devices WHERE user_id = ?)
            AND md.read_at IS NULL
            AND m.conversation_id = c.id AND m.is_unsent = 0
            AND m.sender_id != ?) AS unread_count,
         CASE WHEN c.user_a_id = ? THEN ub.username ELSE ua.username END AS conversant_username,
         CASE WHEN c.user_a_id = ? THEN c.user_b_id ELSE c.user_a_id END AS conversant_id
       FROM conversations c
       JOIN users ua ON ua.id = c.user_a_id
       JOIN users ub ON ub.id = c.user_b_id
       LEFT JOIN conversation_user_settings cus ON cus.conversation_id = c.id AND cus.user_id = ?
       WHERE (c.user_a_id = ? OR c.user_b_id = ?)
         AND (
           (c.request_status = 'pending' AND c.initiated_by_id != ?)
           OR COALESCE(cus.is_restricted, 0) = 1
         )
         AND EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = c.id)
       ORDER BY c.last_message_at DESC NULLS LAST, c.created_at DESC`,
    )
      .bind(
        userId,
        userId,
        userId,
        userId,
        userId,
        userId,
        userId,
        userId,
      )
      .all<{
        id: string;
        disappearing_timer: number;
        created_at: number;
        last_message_at: number | null;
        request_status: string;
        initiated_by_id: string;
        is_restricted: number;
        unread_count: number;
        conversant_username: string;
        conversant_id: string;
      }>();

    const requests = (rows.results ?? []).map((row) => ({
      id: row.id,
      conversant: { id: row.conversant_id, username: row.conversant_username },
      disappearingTimer: row.disappearing_timer,
      requestStatus: row.request_status,
      initiatedById: row.initiated_by_id,
      lastMessageAt: row.last_message_at,
      lastMessagePreview: null,
      unreadCount: row.unread_count,
      createdAt: row.created_at,
      isRestricted: Boolean(row.is_restricted),
    }));

    return new Response(JSON.stringify(requests), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  },
);

conversationsRouter.patch(
  '/requests/:id',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const { id } = request.params as { id: string };
    const conversation = await getConversationForMember(id, userId, env.DB);
    if (!conversation) {
      return new Response(JSON.stringify({ error: 'Message request not found' }), {
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
    const parsed = requestDecisionSchema.safeParse(body);
    if (!parsed.success) {
      return new Response(JSON.stringify({ error: 'Invalid request action' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    if (conversation.initiated_by_id === userId) {
      return new Response(JSON.stringify({ error: 'Only the recipient can respond to a request' }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const nextStatus = parsed.data.action === 'accept' ? 'accepted' : 'rejected';
    if (conversation.request_status !== 'pending') {
      if (conversation.request_status === nextStatus) {
        return new Response(JSON.stringify({ requestStatus: nextStatus }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      return new Response(JSON.stringify({ error: 'Message request is no longer pending' }), {
        status: 409,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    await env.DB.prepare(
      `UPDATE conversations SET request_status = ?
       WHERE id = ? AND request_status = 'pending'`,
    )
      .bind(nextStatus, id)
      .run();

    try {
      const stub = env.CHAT_ROOM.get(env.CHAT_ROOM.idFromName(id));
      await stub.fetch(new Request('https://internal/broadcast', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          type: nextStatus === 'accepted' ? 'request_accepted' : 'request_rejected',
          conversationId: id,
          changedBy: userId,
        }),
      }));
    } catch {
      // The database status remains authoritative if no socket is connected.
    }

    return new Response(JSON.stringify({ requestStatus: nextStatus }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  },
);

conversationsRouter.get(
  '/',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;

    // Fetch all conversations where the user is a participant and not restricted
    const rows = await env.DB.prepare(
      `SELECT
         c.id,
         c.user_a_id,
         c.user_b_id,
         c.disappearing_timer,
         c.created_at,
         c.last_message_at,
         c.request_status,
         c.initiated_by_id,
         COALESCE(cus.is_pinned, 0) AS is_pinned,
         COALESCE(cus.is_muted, 0) AS is_muted,
         COALESCE(cus.is_restricted, 0) AS is_restricted,
         (SELECT COUNT(*) FROM message_deliveries md
          JOIN messages m ON m.id = md.message_id
          WHERE md.recipient_device_id IN (SELECT id FROM devices WHERE user_id = ?)
            AND md.read_at IS NULL
            AND m.conversation_id = c.id AND m.is_unsent = 0
            AND m.sender_id != ?) AS unread_count,
         CASE WHEN c.user_a_id = ? THEN ub.username ELSE ua.username END AS conversant_username,
         CASE WHEN c.user_a_id = ? THEN c.user_b_id ELSE c.user_a_id END AS conversant_id
       FROM conversations c
       JOIN users ua ON ua.id = c.user_a_id
       JOIN users ub ON ub.id = c.user_b_id
       LEFT JOIN conversation_user_settings cus ON cus.conversation_id = c.id AND cus.user_id = ?
       WHERE (c.user_a_id = ? OR c.user_b_id = ?)
         AND COALESCE(cus.is_restricted, 0) = 0
         AND (c.request_status = 'accepted'
           OR (c.request_status = 'pending' AND c.initiated_by_id = ?
             AND EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = c.id)))
       ORDER BY COALESCE(cus.is_pinned, 0) DESC, c.last_message_at DESC NULLS LAST, c.created_at DESC`,
    )
      .bind(
        userId,
        userId,
        userId,
        userId,
        userId,
        userId,
        userId,
        userId,
      )
      .all<{
        id: string;
        user_a_id: string;
        user_b_id: string;
        disappearing_timer: number;
        created_at: number;
        last_message_at: number | null;
        request_status: string;
        initiated_by_id: string | null;
        is_pinned: number;
        is_muted: number;
        is_restricted: number;
        unread_count: number;
        conversant_username: string;
        conversant_id: string;
      }>();

    const conversations = (rows.results ?? []).map((row) => ({
      id: row.id,
      conversant: { id: row.conversant_id, username: row.conversant_username },
      disappearingTimer: row.disappearing_timer,
      requestStatus: row.request_status,
      initiatedById: row.initiated_by_id,
      lastMessageAt: row.last_message_at,
      lastMessagePreview: null, // E2EE — server never decrypts
      unreadCount: row.unread_count,
      createdAt: row.created_at,
      isPinned: Boolean(row.is_pinned),
      isMuted: Boolean(row.is_muted),
      isRestricted: Boolean(row.is_restricted),
    }));

    return new Response(JSON.stringify(conversations), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  },
);

conversationsRouter.get(
  '/:id',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const { id } = request.params as { id: string };

    const conv = await getConversationForMember(id, userId, env.DB);
    if (!conv) {
      return new Response(JSON.stringify({ error: 'Conversation not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const conversantId = conv.user_a_id === userId ? conv.user_b_id : conv.user_a_id;
    const conversant = await env.DB.prepare('SELECT id, username FROM users WHERE id = ?')
      .bind(conversantId)
      .first<{ id: string; username: string }>();

    const unread = await env.DB.prepare(
      `SELECT COUNT(*) AS unread_count FROM message_deliveries md
       JOIN messages m ON m.id = md.message_id
       WHERE md.recipient_device_id IN (SELECT id FROM devices WHERE user_id = ?)
         AND md.read_at IS NULL
         AND m.conversation_id = ? AND m.is_unsent = 0
         AND m.sender_id != ?`,
    )
      .bind(userId, id, userId)
      .first<{ unread_count: number }>();

    return new Response(
      JSON.stringify({
        id: conv.id,
        conversant: conversant ?? { id: conversantId, username: 'unknown' },
        disappearingTimer: conv.disappearing_timer,
        requestStatus: conv.request_status,
        initiatedById: conv.initiated_by_id,
        lastMessageAt: conv.last_message_at,
        lastMessagePreview: null,
        unreadCount: unread?.unread_count ?? 0,
        createdAt: conv.created_at,
      }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );

  },
);

conversationsRouter.patch(
  '/:id/disappearing',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const { id } = request.params as { id: string };

    const conv = await getConversationForMember(id, userId, env.DB);
    if (!conv) {
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

    const parsed = disappearingTimerSchema.safeParse(body);
    if (!parsed.success) {
      return new Response(
        JSON.stringify({
          error: 'Validation failed',
          details: parsed.error.flatten(),
          validValues: VALID_TIMERS,
        }),
        { status: 400, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const { timer } = parsed.data;
    const now = Math.floor(Date.now() / 1000);

    await env.DB.prepare(
      'UPDATE conversations SET disappearing_timer = ? WHERE id = ?',
    )
      .bind(timer, id)
      .run();

    // Insert a system message to record the change
    const msgId = generateId();
    await env.DB.prepare(
      `INSERT INTO messages
         (id, conversation_id, sender_id, message_type, is_unsent, created_at, system_data)
       VALUES (?, ?, ?, 'system', 0, ?, ?)`,
    )
      .bind(
        msgId,
        id,
        userId,
        now,
        JSON.stringify({ event: 'disappearing_timer_changed', timer, changedBy: userId }),
      )
      .run();

    // Notify via Durable Object
    const doId = env.CHAT_ROOM.idFromName(id);
    const stub = env.CHAT_ROOM.get(doId);
    await stub.fetch(
      new Request(`https://internal/broadcast`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          type: 'disappearing_timer_changed',
          conversationId: id,
          timer,
          changedBy: userId,
        }),
      }),
    );

    return new Response(
      JSON.stringify({ conversationId: id, disappearingTimer: timer }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  },
);

const conversationSettingsSchema = z.object({
  isPinned: z.boolean().optional(),
  isMuted: z.boolean().optional(),
  isRestricted: z.boolean().optional(),
});

conversationsRouter.patch(
  '/:id/settings',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const { id } = request.params as { id: string };

    const conversation = await getConversationForMember(id, userId, env.DB);
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

    const parsed = conversationSettingsSchema.safeParse(body);
    if (!parsed.success) {
      return new Response(JSON.stringify({ error: 'Invalid settings body' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const now = Math.floor(Date.now() / 1000);
    const existing = await env.DB.prepare(
      'SELECT * FROM conversation_user_settings WHERE conversation_id = ? AND user_id = ?',
    )
      .bind(id, userId)
      .first<{ id: string; is_pinned: number; is_muted: number; is_restricted: number }>();

    const isPinned = parsed.data.isPinned !== undefined
      ? (parsed.data.isPinned ? 1 : 0)
      : (existing?.is_pinned ?? 0);
    const isMuted = parsed.data.isMuted !== undefined
      ? (parsed.data.isMuted ? 1 : 0)
      : (existing?.is_muted ?? 0);
    const isRestricted = parsed.data.isRestricted !== undefined
      ? (parsed.data.isRestricted ? 1 : 0)
      : (existing?.is_restricted ?? 0);

    if (existing) {
      await env.DB.prepare(
        `UPDATE conversation_user_settings
         SET is_pinned = ?, is_muted = ?, is_restricted = ?, updated_at = ?
         WHERE id = ?`,
      )
        .bind(isPinned, isMuted, isRestricted, now, existing.id)
        .run();
    } else {
      const settingsId = generateId();
      await env.DB.prepare(
        `INSERT INTO conversation_user_settings
         (id, conversation_id, user_id, is_pinned, is_muted, is_restricted, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
        .bind(settingsId, id, userId, isPinned, isMuted, isRestricted, now, now)
        .run();
    }

    return new Response(
      JSON.stringify({
        conversationId: id,
        isPinned: Boolean(isPinned),
        isMuted: Boolean(isMuted),
        isRestricted: Boolean(isRestricted),
      }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  },
);

conversationsRouter.post(
  '/:id/block',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const { id } = request.params as { id: string };

    const conversation = await getConversationForMember(id, userId, env.DB);
    if (!conversation) {
      return new Response(JSON.stringify({ error: 'Conversation not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const otherUserId = conversation.user_a_id === userId ? conversation.user_b_id : conversation.user_a_id;
    const blockId = generateId();
    const now = Math.floor(Date.now() / 1000);

    await env.DB.prepare(
      `INSERT OR IGNORE INTO user_blocks (id, blocker_id, blocked_id, created_at)
       VALUES (?, ?, ?, ?)`,
    )
      .bind(blockId, userId, otherUserId, now)
      .run();

    return new Response(JSON.stringify({ blocked: true, userId: otherUserId }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  },
);

conversationsRouter.delete(
  '/:id/block',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const { id } = request.params as { id: string };

    const conversation = await getConversationForMember(id, userId, env.DB);
    if (!conversation) {
      return new Response(JSON.stringify({ error: 'Conversation not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const otherUserId = conversation.user_a_id === userId ? conversation.user_b_id : conversation.user_a_id;
    await env.DB.prepare(
      'DELETE FROM user_blocks WHERE blocker_id = ? AND blocked_id = ?',
    )
      .bind(userId, otherUserId)
      .run();

    return new Response(JSON.stringify({ blocked: false, userId: otherUserId }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  },
);

export { getConversationForMember };
