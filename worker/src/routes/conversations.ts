import { IRequest, Router } from 'itty-router';
import { z } from 'zod';
import type {
  Env,
  AuthenticatedRequest,
  ConversationRow,
} from '../types.js';
import { authMiddleware } from '../middleware/auth.js';
import { generateId } from '../utils/crypto.js';
import {
  listConversations,
  mapConversationRow,
  parseScope,
} from '../services/conversationList.js';
import { notifyInboxes } from '../services/inbox.js';
import { sendPushToUser } from '../services/push.js';
import type { InboxEvent } from '../services/inbox.js';

export const conversationsRouter = Router({ base: '/api/conversations' });

const createConversationSchema = z.object({
  participantId: z.string().uuid('participantId must be a valid UUID'),
});
const requestDecisionSchema = z.object({
  action: z.enum(['accept', 'reject']),
});

const VALID_TIMERS = [-1, 0, 3600, 21600, 86400, 604800] as const;
const disappearingTimerSchema = z.object({
  timer: z.union([
    z.literal(0),
    z.literal(-1),
    z.literal(3600),
    z.literal(21600),
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

export interface ConversationAccessRow extends ConversationRow {
  /** Two-way block state, resolved in the same read as membership. */
  is_blocked: number;
}

/**
 * Membership and block state from one conversation read. Saves the follow-up
 * `user_blocks` round trip on the send and read paths.
 */
export async function getConversationAccess(
  conversationId: string,
  userId: string,
  db: D1Database,
): Promise<ConversationAccessRow | null> {
  const conv = await db
    .prepare(
      `SELECT c.*,
         EXISTS (
           SELECT 1 FROM user_blocks ub
           WHERE (ub.blocker_id = ? AND ub.blocked_id =
                   CASE WHEN c.user_a_id = ? THEN c.user_b_id ELSE c.user_a_id END)
              OR (ub.blocker_id =
                   CASE WHEN c.user_a_id = ? THEN c.user_b_id ELSE c.user_a_id END
                  AND ub.blocked_id = ?)
         ) AS is_blocked
       FROM conversations c
       WHERE c.id = ? AND (c.user_a_id = ? OR c.user_b_id = ?)`,
    )
    .bind(userId, userId, userId, userId, conversationId, userId, userId)
    .first<ConversationAccessRow>();
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

    // Both chat lists get a "Request sent"/"Message request" tile instantly —
    // no client-side refresh required. List is repairable via REST seed.
    let activeUsers = new Set<string>();
    try {
      const requesterName = myUser?.username ?? 'unknown';
      activeUsers = await notifyInboxes(env, [userId, participantId], (targetUserId) => [
        {
          type: 'conversation_upsert',
          conversation: {
            id: convId,
            conversant: targetUserId === userId
              ? { id: participant.id, username: participant.username }
              : { id: userId, username: requesterName },
            disappearingTimer: 0,
            requestStatus: 'pending',
            initiatedById: userId,
            lastMessageAt: null,
            lastMessagePreview: null,
            unreadCount: 0,
            createdAt: now,
            isPinned: false,
            isMuted: false,
            isRestricted: false,
          },
        } as InboxEvent,
      ]);
    } catch {
      // Non-fatal.
    }

    // Best-effort FCM push so the recipient learns about the request even with
    // the app closed. Failures never affect the request itself.
    try {
      if (!activeUsers.has(participantId)) {
        await sendPushToUser(env, participantId, {
          title: myUser?.username ?? 'New message request',
          body: 'Sent you a message request',
          data: { type: 'request', conversationId: convId },
        });
      }
    } catch {
      // Non-fatal.
    }

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

conversationsRouter.patch(
  '/:id/request',
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
          events: [{
            type: nextStatus === 'accepted' ? 'request_accepted' : 'request_rejected',
            conversationId: id,
            changedBy: userId,
          }],
        }),
      }));
    } catch {
      // The database status remains authoritative if no socket is connected.
    }

    // Push the status flip into BOTH participants' chat lists over their inbox
    // sockets — accept promotes the "Request sent" tile, reject drops it.
    try {
      const otherId = conversation.user_a_id === userId ? conversation.user_b_id : conversation.user_a_id;
      const nameRows = await env.DB.prepare(
        `SELECT id, username FROM users WHERE id IN (?, ?)`,
      ).bind(userId, otherId).all<{ id: string; username: string }>();
      const names = new Map((nameRows.results ?? []).map((u) => [u.id, u.username]));

      const upsertEvent = (targetUserId: string) => ({
        type: 'conversation_upsert',
        conversation: {
          id,
          conversant: {
            id: targetUserId === userId ? otherId : userId,
            username: targetUserId === userId
              ? names.get(otherId) ?? 'unknown'
              : names.get(userId) ?? 'unknown',
          },
          disappearingTimer: conversation.disappearing_timer ?? 0,
          requestStatus: nextStatus,
          initiatedById: conversation.initiated_by_id,
          lastMessageAt: conversation.last_message_at ?? null,
          lastMessagePreview: null,
          unreadCount: 0,
          createdAt: conversation.created_at,
          isPinned: false,
          isMuted: false,
          isRestricted: false,
        },
      });
      await notifyInboxes(env, [userId, otherId], (target) => [upsertEvent(target) as InboxEvent]);
    } catch {
      // Non-fatal: REST seed repairs the list on next app resume / refresh.
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
    const scope = parseScope(new URL(request.url));

    if (scope === 'all') {
      // Single-seed payload: accepted chats + request queue in one round trip.
      const [rows, requestRows] = await Promise.all([
        listConversations(env, userId, 'inbox'),
        listConversations(env, userId, 'requests'),
      ]);
      return new Response(
        JSON.stringify({
          conversations: rows.map((row) => mapConversationRow(row)),
          requests: requestRows.map((row) => mapConversationRow(row)),
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const rows = await listConversations(env, userId, scope);
    const payload = rows.map((row) => mapConversationRow(row));
    return new Response(JSON.stringify(payload), {
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

    await env.DB.prepare(
      'UPDATE conversations SET disappearing_timer = ? WHERE id = ?',
    )
      .bind(timer, id)
      .run();

    if (timer === 0) {
      await env.DB.prepare(
        'UPDATE messages SET expires_at = NULL WHERE conversation_id = ?',
      )
        .bind(id)
        .run();
    }

    // Notify via Durable Object
    const doId = env.CHAT_ROOM.idFromName(id);
    const stub = env.CHAT_ROOM.get(doId);
    await stub.fetch(
      new Request(`https://internal/broadcast`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          events: [{
            type: 'disappearing_timer_changed',
            conversationId: id,
            timer,
            changedBy: userId,
          }],
        }),
      }),
    );

    // Both chat lists mirror the shared timer immediately.
    await notifyInboxes(env, [conv.user_a_id, conv.user_b_id], () => [
      { type: 'conversation_refresh', conversationId: id },
    ]);

    return new Response(
      JSON.stringify({ conversationId: id, disappearingTimer: timer }),
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
