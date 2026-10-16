import type { Env } from '../types.js';

/**
 * Shared projection for the conversations list. The inbox list and the
 * message-requests list are the same shape — one SQL projection, one mapper,
 * filtered by scope. Routes stay thin and the payload contract stays
 * identical no matter which scope the client asks for.
 */

export type ConversationScope = 'inbox' | 'requests' | 'all';

export interface ConversationListRow {
  id: string;
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
}

export function parseScope(url: URL): ConversationScope {
  const value = (url.searchParams.get('scope') || 'inbox').toLowerCase();
  if (value === 'requests' || value === 'all') return value;
  return 'inbox';
}

const INBOX_WHERE = `
      COALESCE(cus.is_restricted, 0) = 0
      AND (c.request_status = 'accepted'
        OR (c.request_status = 'pending'
          AND c.initiated_by_id = ?
          AND EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = c.id)))`;

const REQUESTS_WHERE = `
      (
        (c.request_status = 'pending' AND c.initiated_by_id != ?)
        OR COALESCE(cus.is_restricted, 0) = 1
      )
      AND EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = c.id)`;

/** Per-device unread counter, scoped to one user's devices */
const UNREAD_COUNT = `(SELECT COUNT(*) FROM message_deliveries md
     JOIN messages m ON m.id = md.message_id
     WHERE md.recipient_device_id IN (SELECT id FROM devices WHERE user_id = ?)
       AND md.read_at IS NULL
       AND m.conversation_id = c.id AND m.is_unsent = 0
       AND m.sender_id != ?)`;

/**
 * Builds the chat-row projection for one user.
 * Binds (in order): device/unread sub-query (2), chat-list selectors (2),
 * settings join (1), participants (2), scope filter (1).
 */
export function conversationListQuery(
  userId: string,
  scope: Exclude<ConversationScope, 'all'>,
): { sql: string; binds: string[] } {
  const sql = `
    SELECT
      c.id,
      c.disappearing_timer,
      c.created_at,
      c.last_message_at,
      c.request_status,
      c.initiated_by_id,
      COALESCE(cus.is_pinned, 0) AS is_pinned,
      COALESCE(cus.is_muted, 0) AS is_muted,
      COALESCE(cus.is_restricted, 0) AS is_restricted,
      ${UNREAD_COUNT} AS unread_count,
      CASE WHEN c.user_a_id = ? THEN ub.username ELSE ua.username END AS conversant_username,
      CASE WHEN c.user_a_id = ? THEN c.user_b_id ELSE c.user_a_id END AS conversant_id
    FROM conversations c
    JOIN users ua ON ua.id = c.user_a_id
    JOIN users ub ON ub.id = c.user_b_id
    LEFT JOIN conversation_user_settings cus ON cus.conversation_id = c.id AND cus.user_id = ?
    WHERE (c.user_a_id = ? OR c.user_b_id = ?)
      AND ${scope === 'requests' ? REQUESTS_WHERE : INBOX_WHERE}
    ORDER BY COALESCE(cus.is_pinned, 0) DESC, c.last_message_at DESC NULLS LAST, c.created_at DESC`;

  return { sql, binds: [userId, userId, userId, userId, userId, userId, userId, userId] };
}

/** Row → client payload (snake_case + camelCase tolerant, client-safe). */
export function mapConversationRow(
  row: ConversationListRow,
  opts: { restricted?: boolean } = {},
): Record<string, unknown> {
  return {
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
    isRestricted: opts.restricted ?? Boolean(row.is_restricted),
  };
}

export async function listConversations(
  env: Env,
  userId: string,
  scope: Exclude<ConversationScope, 'all'>,
): Promise<ConversationListRow[]> {
  const { sql, binds } = conversationListQuery(userId, scope as 'inbox');
  const rows = await env.DB.prepare(sql).bind(...binds).all<ConversationListRow>();
  return rows.results ?? [];
}
