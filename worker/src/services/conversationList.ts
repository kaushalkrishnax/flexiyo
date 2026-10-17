import type { Env } from '../types.js';

export type ConversationScope = 'inbox' | 'requests' | 'blocked' | 'all';

export interface ConversationListRow {
  id: string;
  disappearing_timer: number;
  created_at: number;
  last_message_at: number | null;
  request_status: string;
  initiated_by_id: string | null;
  unread_count: number;
  conversant_username: string;
  conversant_id: string;
  peer_seen_at: number | null;
  last_message_is_mine: number | null;
}

export function parseScope(url: URL): ConversationScope {
  const value = (url.searchParams.get('scope') || 'inbox').toLowerCase();
  if (value === 'requests' || value === 'blocked' || value === 'all') return value;
  return 'inbox';
}

const INBOX_WHERE = `
      (c.request_status = 'accepted'
        OR (c.request_status = 'pending'
          AND c.initiated_by_id = ?
          AND EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = c.id AND m.is_unsent = 0)))
      AND NOT EXISTS (SELECT 1 FROM user_blocks ub
        WHERE ub.blocker_id = ? AND ub.blocked_id =
          CASE WHEN c.user_a_id = ? THEN c.user_b_id ELSE c.user_a_id END)`;

const REQUESTS_WHERE = `
      (c.request_status = 'pending' AND c.initiated_by_id != ?)
       AND EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = c.id AND m.is_unsent = 0)
      AND NOT EXISTS (SELECT 1 FROM user_blocks ub
        WHERE ub.blocker_id = ? AND ub.blocked_id =
          CASE WHEN c.user_a_id = ? THEN c.user_b_id ELSE c.user_a_id END)`;

const BLOCKED_WHERE = `
      EXISTS (SELECT 1 FROM user_blocks ub
        WHERE ub.blocker_id = ? AND ub.blocked_id =
          CASE WHEN c.user_a_id = ? THEN c.user_b_id ELSE c.user_a_id END)
       AND EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = c.id AND m.is_unsent = 0)`;

const UNREAD_COUNT = `(SELECT COUNT(*) FROM message_deliveries md
      JOIN messages m ON m.id = md.message_id
      WHERE md.recipient_device_id IN (SELECT id FROM devices WHERE user_id = ?)
        AND md.read_at IS NULL
        AND m.conversation_id = c.id AND m.is_unsent = 0
        AND m.sender_id != ?)`;

/// When the conversant last read a message of mine (drives "Seen …" labels).
const PEER_SEEN_AT = `(SELECT MAX(md.read_at) FROM message_deliveries md
      JOIN messages m ON m.id = md.message_id
      WHERE m.conversation_id = c.id AND m.sender_id = ?
        AND m.is_unsent = 0 AND md.read_at IS NOT NULL)`;

/// Whether the newest message is mine, so the inbox only shows a read
/// receipt when the conversant has seen that message.
const LAST_MESSAGE_IS_MINE = `(SELECT CASE WHEN m.sender_id = ? THEN 1 ELSE 0 END
      FROM messages m
      WHERE m.conversation_id = c.id AND m.is_unsent = 0
      ORDER BY m.created_at DESC, m.id DESC LIMIT 1)`;


export function conversationListQuery(
  userId: string,
  scope: Exclude<ConversationScope, 'all'>,
): { sql: string; binds: string[] } {
  const binds: string[] = [];
  binds.push(userId, userId); // unread sub-query
  binds.push(userId, userId); // peer seen + last message sender
  binds.push(userId, userId); // participants selectors
  binds.push(userId, userId); // participants WHERE
  if (scope === 'inbox') {
    binds.push(userId); // initiated_by_id
    binds.push(userId, userId); // user_blocks blocker + case
  } else if (scope === 'requests') {
    binds.push(userId, userId, userId); // user_blocks (3)
  } else {
    binds.push(userId, userId); // user_blocks blocker + case (2)
  }
  const where =
    scope === 'requests'
      ? REQUESTS_WHERE
      : scope === 'blocked'
        ? BLOCKED_WHERE
        : INBOX_WHERE;
  const sql = `
    SELECT
      c.id,
      c.disappearing_timer,
      c.created_at,
      CASE WHEN EXISTS (
        SELECT 1 FROM messages old_deleted
        WHERE old_deleted.conversation_id = c.id AND old_deleted.is_unsent = 1
      ) THEN (
        SELECT MAX(active_message.created_at) FROM messages active_message
        WHERE active_message.conversation_id = c.id AND active_message.is_unsent = 0
      ) ELSE c.last_message_at END AS last_message_at,
      c.request_status,
      c.initiated_by_id,
      ${UNREAD_COUNT} AS unread_count,
      ${PEER_SEEN_AT} AS peer_seen_at,
      ${LAST_MESSAGE_IS_MINE} AS last_message_is_mine,
      CASE WHEN c.user_a_id = ? THEN ub.username ELSE ua.username END AS conversant_username,
      CASE WHEN c.user_a_id = ? THEN c.user_b_id ELSE c.user_a_id END AS conversant_id
    FROM conversations c
    JOIN users ua ON ua.id = c.user_a_id
    JOIN users ub ON ub.id = c.user_b_id
    WHERE (c.user_a_id = ? OR c.user_b_id = ?)
      AND ${where}
    ORDER BY c.last_message_at DESC NULLS LAST, c.created_at DESC`;
  return { sql, binds };
}

export function mapConversationRow(
  row: ConversationListRow,
): Record<string, unknown> {
  return {
    id: row.id,
    conversant: { id: row.conversant_id, username: row.conversant_username },
    disappearingTimer: row.disappearing_timer,
    requestStatus: row.request_status,
    initiatedById: row.initiated_by_id,
    lastMessageAt: row.last_message_at,
    lastMessagePreview: null,
    unreadCount: row.unread_count,
    peerSeenAt: row.peer_seen_at ?? null,
    lastMessageIsMine: row.last_message_is_mine === 1,
    createdAt: row.created_at,
  };
}

export async function listConversations(
  env: Env,
  userId: string,
  scope: Exclude<ConversationScope, 'all'>,
): Promise<ConversationListRow[]> {
  const { sql, binds } = conversationListQuery(userId, scope);
  const rows = await env.DB.prepare(sql).bind(...binds).all<ConversationListRow>();
  return rows.results ?? [];
}
