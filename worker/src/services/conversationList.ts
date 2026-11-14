import type { Env } from '../types.js';
import { getSqlDb } from '../database/turso.js';

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

export function conversationListQuery(
  userId: string,
  scope: ConversationScope,
): { sql: string; binds: string[] } {
  const binds = [
    userId,
    userId,
    userId,
    userId,
    userId,
    userId,
  ];

  let scopeWhere: string;
  if (scope === 'inbox') {
    scopeWhere = `
      blk.id IS NULL
      AND (
        c.request_status = 'accepted'
        OR (
          c.request_status = 'pending'
          AND c.initiated_by_id = ?
          AND c.last_message_at IS NOT NULL
        )
      )`;
    binds.push(userId);
  } else if (scope === 'requests') {
    scopeWhere = `
      blk.id IS NULL
      AND c.request_status = 'pending'
      AND c.initiated_by_id != ?
      AND c.last_message_at IS NOT NULL`;
    binds.push(userId);
  } else if (scope === 'blocked') {
    scopeWhere = `
      blk.id IS NOT NULL
      AND c.last_message_at IS NOT NULL`;
  } else {
    scopeWhere = `
      blk.id IS NULL
      AND (
        c.request_status = 'accepted'
        OR (
          c.request_status = 'pending'
          AND c.initiated_by_id IS NOT NULL
          AND c.last_message_at IS NOT NULL
        )
      )`;
  }

  const sql = `
    SELECT
      c.id,
      c.disappearing_timer,
      c.created_at,
      c.last_message_at,
      c.request_status,
      c.initiated_by_id,
      cus.unread_count,
      cus.peer_seen_at,
      CASE
        WHEN c.last_message_sender_id IS NULL THEN NULL
        WHEN c.last_message_sender_id = ? THEN 1
        ELSE 0
      END AS last_message_is_mine,
      CASE WHEN c.user_a_id = ? THEN ub.username ELSE ua.username END AS conversant_username,
      CASE WHEN c.user_a_id = ? THEN c.user_b_id ELSE c.user_a_id END AS conversant_id
    FROM conversation_user_state cus
    JOIN conversations c ON c.id = cus.conversation_id
    JOIN users ua ON ua.id = c.user_a_id
    JOIN users ub ON ub.id = c.user_b_id
    LEFT JOIN user_blocks blk
      ON blk.blocker_id = ?
     AND blk.blocked_id = CASE WHEN c.user_a_id = ? THEN c.user_b_id ELSE c.user_a_id END
    WHERE cus.user_id = ?
      AND ${scopeWhere}
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
  const db = getSqlDb(env);
  const { sql, binds } = conversationListQuery(userId, scope);
  const rows = await db.prepare(sql).bind(...binds).all<ConversationListRow>();
  return rows.results ?? [];
}

export async function listAllConversations(
  env: Env,
  userId: string,
): Promise<{ conversations: ConversationListRow[]; requests: ConversationListRow[] }> {
  const db = getSqlDb(env);
  const { sql, binds } = conversationListQuery(userId, 'all');
  const result = await db.prepare(sql).bind(...binds).all<ConversationListRow>();
  const conversations: ConversationListRow[] = [];
  const requests: ConversationListRow[] = [];

  for (const row of result.results ?? []) {
    if (row.request_status === 'pending' && row.initiated_by_id !== userId) {
      requests.push(row);
    } else {
      conversations.push(row);
    }
  }

  return { conversations, requests };
}
