import type { Env } from '../types.js';
import { notifyInboxes } from './inbox.js';
import { runBatched } from '../utils/d1.js';
import { postChatRoomJson } from '../utils/durableObject.js';
import { getSqlDb, type SqlStatement } from '../database/turso.js';

interface DeletionImpactRow {
  sender_id: string;
  unread_deleted: number;
  read_deleted: number;
}

export async function deleteMessages(
  env: Env,
  conversationId: string,
  messageIds: string[],
): Promise<void> {
  const ids = [...new Set(messageIds)];
  if (ids.length === 0) return;
  const db = getSqlDb(env);
  const idSet = JSON.stringify(ids);

  const [deletedMedia, deletionImpacts] = await db.batch([
    db.prepare(
      `SELECT media.id AS id, media.r2_key AS r2_key
       FROM json_each(?) ids
       CROSS JOIN messages m
       JOIN media ON media.id = m.media_id
       WHERE m.id = ids.value AND m.conversation_id = ?`,
    ).bind(idSet, conversationId),
    db.prepare(
      `SELECT
         m.sender_id AS sender_id,
         SUM(CASE WHEN m.read_at IS NULL THEN 1 ELSE 0 END) AS unread_deleted,
         SUM(CASE WHEN m.read_at IS NOT NULL THEN 1 ELSE 0 END) AS read_deleted
       FROM json_each(?) ids
       CROSS JOIN messages m
       WHERE m.id = ids.value
         AND m.conversation_id = ?
         AND m.is_unsent = 0
       GROUP BY m.sender_id`,
    ).bind(idSet, conversationId),
    db.prepare(
      `DELETE FROM messages
       WHERE rowid IN (
         SELECT m.rowid
         FROM json_each(?) ids
         CROSS JOIN messages m
         WHERE m.id = ids.value AND m.conversation_id = ?
       )`,
    ).bind(idSet, conversationId),
  ]);

  const media = (deletedMedia.results ?? []) as Array<{ id: string; r2_key: string }>;
  if (media.length > 0) {
    const outcomes = await Promise.allSettled(media.map((item) => env.MEDIA.delete(item.r2_key)));
    const removed = media.filter((_, index) => outcomes[index]?.status === 'fulfilled');
    const retry = media.filter((_, index) => outcomes[index]?.status === 'rejected');
    if (removed.length > 0) {
      await runBatched(
        db,
        removed.map((item) => db.prepare('DELETE FROM media WHERE id = ?').bind(item.id)),
      );
    }
    if (retry.length > 0) {
      const retryAt = Math.floor(Date.now() / 1000) + 3_600;
      await runBatched(
        db,
        retry.map((item) =>
          db.prepare(
            `UPDATE media SET consumed = 1, expires_at = ? WHERE id = ?`,
          ).bind(retryAt, item.id),
        ),
      );
    }
  }

  const [conversationResult, latestResult] = await db.batch([
    db.prepare('SELECT user_a_id, user_b_id FROM conversations WHERE id = ?').bind(
      conversationId,
    ),
    db.prepare(
      `SELECT created_at, sender_id
       FROM messages
       WHERE conversation_id = ? AND is_unsent = 0
       ORDER BY created_at DESC, id DESC
       LIMIT 1`,
    ).bind(conversationId),
  ]);

  const conversation = conversationResult.results?.[0] as
    | { user_a_id: string; user_b_id: string }
    | undefined;
  const latest = latestResult.results?.[0] as
    | { created_at: number; sender_id: string }
    | undefined;

  const stateStatements: SqlStatement[] = [
    db.prepare(
      `UPDATE conversations
       SET last_message_at = ?, last_message_sender_id = ?
       WHERE id = ?`,
    ).bind(latest?.created_at ?? null, latest?.sender_id ?? null, conversationId),
  ];

  if (conversation) {
    const impacts = (deletionImpacts.results ?? []) as unknown as DeletionImpactRow[];
    for (const impact of impacts) {
      const recipientId =
        impact.sender_id === conversation.user_a_id
          ? conversation.user_b_id
          : conversation.user_a_id;

      if (impact.unread_deleted > 0) {
        stateStatements.push(
          db.prepare(
            `UPDATE conversation_user_state
             SET unread_count = MAX(0, unread_count - ?)
             WHERE conversation_id = ? AND user_id = ?`,
          ).bind(impact.unread_deleted, conversationId, recipientId),
        );
      }

      if (impact.read_deleted > 0) {
        stateStatements.push(
          db.prepare(
            `UPDATE conversation_user_state
             SET peer_seen_at = (
               SELECT MAX(read_at) FROM messages
               WHERE conversation_id = ? AND sender_id = ? AND is_unsent = 0 AND read_at IS NOT NULL
             )
             WHERE conversation_id = ? AND user_id = ?`,
          ).bind(conversationId, impact.sender_id, conversationId, impact.sender_id),
        );
      }
    }
  }

  await runBatched(db, stateStatements);

  await postChatRoomJson(env, conversationId, '/broadcast', {
    events: ids.map((messageId) => ({
      type: 'message_deleted',
      messageId,
      conversationId,
    })),
  });

  if (conversation) {
    await notifyInboxes(env, [conversation.user_a_id, conversation.user_b_id], () => [
      { type: 'conversation_refresh', conversationId },
    ]);
  }
}
