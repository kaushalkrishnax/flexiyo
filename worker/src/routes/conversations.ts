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
  listAllConversations,
  listConversations,
  mapConversationRow,
  parseScope,
} from '../services/conversationList.js';
import { notifyInboxes } from '../services/inbox.js';
import { sendPushToUser } from '../services/push.js';
import type { InboxEvent } from '../services/inbox.js';
import { readJsonBody } from '../utils/http.js';
import { postChatRoomJson } from '../utils/durableObject.js';

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
  is_blocked: number;
}

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

    const bodyResult = await readJsonBody(request);
    if (!bodyResult.ok) return bodyResult.response;
    const body = bodyResult.body;

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

    const [userA, userB] =
      userId < participantId ? [userId, participantId] : [participantId, userId];

    const existing = await env.DB.prepare(
      `SELECT c.*, COALESCE(cus.unread_count, 0) AS unread_count
       FROM conversations c
       LEFT JOIN conversation_user_state cus
         ON cus.conversation_id = c.id AND cus.user_id = ?
       WHERE c.user_a_id = ? AND c.user_b_id = ?`,
    )
      .bind(userId, userA, userB)
      .first<ConversationRow & { unread_count: number }>();

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
          unreadCount: existing.unread_count ?? 0,
          createdAt: existing.created_at,
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const convId = generateId();
    const now = Math.floor(Date.now() / 1000);

    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO conversations
           (id, user_a_id, user_b_id, initiated_by_id, request_status, disappearing_timer, created_at)
         VALUES (?, ?, ?, ?, 'pending', 0, ?)`,
      ).bind(convId, userA, userB, userId, now),
      env.DB.prepare(
        `INSERT OR IGNORE INTO conversation_user_state (conversation_id, user_id, unread_count)
         VALUES (?, ?, 0)`,
      ).bind(convId, userA),
      env.DB.prepare(
        `INSERT OR IGNORE INTO conversation_user_state (conversation_id, user_id, unread_count)
         VALUES (?, ?, 0)`,
      ).bind(convId, userB),
    ]);

    const myUser = await env.DB.prepare('SELECT username FROM users WHERE id = ?')
      .bind(userId)
      .first<{ username: string }>();

    let activeUsers = new Set<string>();
    try {
      const requesterName = myUser?.username ?? 'unknown';
      activeUsers = await notifyInboxes(env, [userId, participantId], (targetUserId) => [
        {
          type: 'conversation_upsert',
          conversation: {
            id: convId,
            conversant:
              targetUserId === userId
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
      // List stays repairable via REST resync.
    }

    try {
      if (!activeUsers.has(participantId)) {
        await sendPushToUser(env, participantId, {
          title: myUser?.username ?? 'New message request',
          body: 'Sent you a message request',
          data: { type: 'request', conversationId: convId },
        });
      }
    } catch {
      // Push failures must not abort conversation creation.
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

    const bodyResult = await readJsonBody(request);
    if (!bodyResult.ok) return bodyResult.response;
    const parsed = requestDecisionSchema.safeParse(bodyResult.body);
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
      await postChatRoomJson(env, id, '/broadcast', {
        events: [
          {
            type: nextStatus === 'accepted' ? 'request_accepted' : 'request_rejected',
            conversationId: id,
            changedBy: userId,
          },
        ],
      });
    } catch {
      // Database status remains authoritative if no room socket is open.
    }

    try {
      const otherId =
        conversation.user_a_id === userId ? conversation.user_b_id : conversation.user_a_id;
      const [namesResult, stateResult] = await env.DB.batch([
        env.DB.prepare(`SELECT id, username FROM users WHERE id IN (?, ?)`).bind(userId, otherId),
        env.DB.prepare(
          `SELECT user_id, unread_count FROM conversation_user_state
           WHERE conversation_id = ? AND user_id IN (?, ?)`,
        ).bind(id, userId, otherId),
      ]);
      const names = new Map(
        ((namesResult.results ?? []) as Array<{ id: string; username: string }>).map((u) => [
          u.id,
          u.username,
        ]),
      );
      const unreadMap = new Map(
        ((stateResult.results ?? []) as Array<{ user_id: string; unread_count: number }>).map(
          (s) => [s.user_id, s.unread_count],
        ),
      );

      const upsertEvent = (targetUserId: string) => ({
        type: 'conversation_upsert',
        conversation: {
          id,
          conversant: {
            id: targetUserId === userId ? otherId : userId,
            username:
              targetUserId === userId
                ? names.get(otherId) ?? 'unknown'
                : names.get(userId) ?? 'unknown',
          },
          disappearingTimer: conversation.disappearing_timer ?? 0,
          requestStatus: nextStatus,
          initiatedById: conversation.initiated_by_id,
          lastMessageAt: conversation.last_message_at ?? null,
          lastMessagePreview: null,
          unreadCount: unreadMap.get(targetUserId) ?? 0,
          createdAt: conversation.created_at,
          isPinned: false,
          isMuted: false,
          isRestricted: false,
        },
      });
      await notifyInboxes(env, [userId, otherId], (target) => [upsertEvent(target) as InboxEvent]);
    } catch {
      // Repairable via REST resync on next refresh.
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
      const { conversations, requests } = await listAllConversations(env, userId);
      return new Response(
        JSON.stringify({
          conversations: conversations.map((row) => mapConversationRow(row)),
          requests: requests.map((row) => mapConversationRow(row)),
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const rows = await listConversations(env, userId, scope);
    return new Response(JSON.stringify(rows.map((row) => mapConversationRow(row))), {
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

    const row = await env.DB.prepare(
      `SELECT
         c.id,
         c.disappearing_timer,
         c.request_status,
         c.initiated_by_id,
         c.last_message_at,
         c.last_message_sender_id,
         c.created_at,
         COALESCE(cus.unread_count, 0) AS unread_count,
         cus.peer_seen_at,
         u.id AS conversant_id,
         u.username AS conversant_username
       FROM conversations c
       JOIN users u
         ON u.id = CASE WHEN c.user_a_id = ? THEN c.user_b_id ELSE c.user_a_id END
       LEFT JOIN conversation_user_state cus
         ON cus.conversation_id = c.id AND cus.user_id = ?
       WHERE c.id = ? AND (c.user_a_id = ? OR c.user_b_id = ?)`,
    )
      .bind(userId, userId, id, userId, userId)
      .first<{
        id: string;
        disappearing_timer: number;
        request_status: string;
        initiated_by_id: string | null;
        last_message_at: number | null;
        last_message_sender_id: string | null;
        created_at: number;
        unread_count: number;
        peer_seen_at: number | null;
        conversant_id: string;
        conversant_username: string;
      }>();

    if (!row) {
      return new Response(JSON.stringify({ error: 'Conversation not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    return new Response(
      JSON.stringify({
        id: row.id,
        conversant: { id: row.conversant_id, username: row.conversant_username },
        disappearingTimer: row.disappearing_timer,
        requestStatus: row.request_status,
        initiatedById: row.initiated_by_id,
        lastMessageAt: row.last_message_at,
        lastMessagePreview: null,
        unreadCount: row.unread_count,
        peerSeenAt: row.peer_seen_at ?? null,
        lastMessageIsMine: row.last_message_sender_id === userId,
        createdAt: row.created_at,
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

    const bodyResult = await readJsonBody(request);
    if (!bodyResult.ok) return bodyResult.response;
    const parsed = disappearingTimerSchema.safeParse(bodyResult.body);
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

    await postChatRoomJson(env, id, '/broadcast', {
      events: [
        {
          type: 'disappearing_timer_changed',
          conversationId: id,
          timer,
          changedBy: userId,
        },
      ],
    });

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

    const otherUserId =
      conversation.user_a_id === userId ? conversation.user_b_id : conversation.user_a_id;
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

    const otherUserId =
      conversation.user_a_id === userId ? conversation.user_b_id : conversation.user_a_id;
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
