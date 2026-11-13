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

export function conversationListQuery(
  userId: string,
  scope: Exclude<ConversationScope, 'all'>,
): { sql: string; binds: string[] } {
  const whereBinds: string[] = [];
  if (scope === 'inbox') {
    whereBinds.push(userId, userId, userId); // initiated_by_id + block check
  } else if (scope === 'requests') {
    whereBinds.push(userId, userId, userId); // initiator + block check
  } else {
    whereBinds.push(userId, userId); // block check
  }

  const where =
    scope === 'requests'
      ? REQUESTS_WHERE
      : scope === 'blocked'
        ? BLOCKED_WHERE
        : INBOX_WHERE;

  // Aggregate receipt data once per conversation instead of running correlated
  // delivery/message scans independently for every inbox row.
  const binds = [
    userId, // user_devices
    userId, userId, // conversation participants
    ...whereBinds,
    userId, // v1 unread sender exclusion
    userId, // v2 unread sender exclusion
    userId, // v1 peer seen sender
    userId, // v2 peer seen sender
    userId, // latest message sender
    userId, userId, // conversant username/id selectors
  ];

  const sql = `
    WITH
    user_devices AS MATERIALIZED (
      SELECT id FROM devices WHERE user_id = ?
    ),
    user_conversations AS MATERIALIZED (
      SELECT c.*
      FROM conversations c
      WHERE (c.user_a_id = ? OR c.user_b_id = ?)
        AND ${where}
    ),
    v1_unread AS (
      SELECT m.conversation_id, COUNT(DISTINCT m.id) AS unread_count
      FROM user_conversations uc
      CROSS JOIN messages m
      CROSS JOIN message_deliveries md
      WHERE m.conversation_id = uc.id
        AND md.message_id = m.id
        AND md.recipient_device_id IN (SELECT id FROM user_devices)
        AND md.read_at IS NULL
        AND m.is_unsent = 0
        AND m.encryption_version = 1
        AND m.sender_id != ?
      GROUP BY m.conversation_id
    ),
    v2_unread AS (
      SELECT m.conversation_id, COUNT(*) AS unread_count
      FROM user_conversations uc
      CROSS JOIN messages m
      WHERE m.conversation_id = uc.id
        AND m.is_unsent = 0
        AND m.encryption_version = 2
        AND m.sender_id != ?
        AND m.read_at IS NULL
      GROUP BY m.conversation_id
    ),
    v1_peer_seen AS (
      SELECT m.conversation_id, MAX(md.read_at) AS peer_seen_at
      FROM user_conversations uc
      CROSS JOIN messages m
      JOIN message_deliveries md ON md.message_id = m.id
      WHERE m.conversation_id = uc.id
        AND m.sender_id = ?
        AND m.is_unsent = 0
        AND m.encryption_version = 1
        AND md.read_at IS NOT NULL
      GROUP BY m.conversation_id
    ),
    v2_peer_seen AS (
      SELECT m.conversation_id, MAX(m.read_at) AS peer_seen_at
      FROM user_conversations uc
      CROSS JOIN messages m
      WHERE m.conversation_id = uc.id
        AND m.sender_id = ?
        AND m.is_unsent = 0
        AND m.encryption_version = 2
        AND m.read_at IS NOT NULL
      GROUP BY m.conversation_id
    )
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
      COALESCE(v1_unread.unread_count, 0) + COALESCE(v2_unread.unread_count, 0) AS unread_count,
      NULLIF(MAX(
        COALESCE(v1_peer_seen.peer_seen_at, 0),
        COALESCE(v2_peer_seen.peer_seen_at, 0)
      ), 0) AS peer_seen_at,
      (SELECT CASE WHEN m.sender_id = ? THEN 1 ELSE 0 END
       FROM messages m
       WHERE m.conversation_id = c.id AND m.is_unsent = 0
       ORDER BY m.created_at DESC, m.id DESC LIMIT 1) AS last_message_is_mine,
      CASE WHEN c.user_a_id = ? THEN ub.username ELSE ua.username END AS conversant_username,
      CASE WHEN c.user_a_id = ? THEN c.user_b_id ELSE c.user_a_id END AS conversant_id
    FROM user_conversations c
    JOIN users ua ON ua.id = c.user_a_id
    JOIN users ub ON ub.id = c.user_b_id
    LEFT JOIN v1_unread ON v1_unread.conversation_id = c.id
    LEFT JOIN v2_unread ON v2_unread.conversation_id = c.id
    LEFT JOIN v1_peer_seen ON v1_peer_seen.conversation_id = c.id
    LEFT JOIN v2_peer_seen ON v2_peer_seen.conversation_id = c.id
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
