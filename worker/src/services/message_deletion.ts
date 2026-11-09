import type { Env } from '../types.js';
import { notifyInboxes } from './inbox.js';
import { runBatched } from '../utils/d1.js';

export async function deleteMessages(
  env: Env,
  conversationId: string,
  messageIds: string[],
): Promise<void> {
  const ids = [...new Set(messageIds)];
  if (ids.length === 0) return;
  const idSet = JSON.stringify(ids);

  // Media is linked from the message (`messages.media_id`), not the other way
  // round. Scope both the select and the delete to this conversation so a
  // mismatched id can never orphan media from another chat.
  const [deletedMedia] = await env.DB.batch<{ id: string; r2_key: string }>([
    env.DB.prepare(
      `SELECT media.id AS id, media.r2_key AS r2_key
       FROM messages m
       JOIN media ON media.id = m.media_id
       WHERE m.conversation_id = ?
         AND m.id IN (SELECT value FROM json_each(?))`,
    ).bind(conversationId, idSet),
    // One statement instead of one per message: a 500-message expiry sweep
    // stays well below D1's per-batch statement budget.
    env.DB.prepare(
      `DELETE FROM messages
       WHERE conversation_id = ?
         AND id IN (SELECT value FROM json_each(?))`,
    ).bind(conversationId, idSet),
  ]);

  const media = deletedMedia.results ?? [];
  if (media.length > 0) {
    // R2 first: a row without its object is unrecoverable, an orphan object is
    // not (it expires with the bucket lifecycle). Deletes run concurrently so
    // a sweep with many attachments is not serialized on network latency.
    await Promise.allSettled(media.map((item) => env.MEDIA.delete(item.r2_key)));
    await runBatched(
      env.DB,
      media.flatMap((item) => [
        env.DB.prepare('DELETE FROM media_views WHERE media_id = ?').bind(item.id),
        env.DB.prepare('DELETE FROM media WHERE id = ?').bind(item.id),
      ]),
    );
  }

  const latest = await env.DB.prepare(
    `SELECT MAX(created_at) AS last_message_at
     FROM messages WHERE conversation_id = ? AND is_unsent = 0`,
  )
    .bind(conversationId)
    .first<{ last_message_at: number | null }>();
  await env.DB.prepare(
    'UPDATE conversations SET last_message_at = ? WHERE id = ?',
  )
    .bind(latest?.last_message_at ?? null, conversationId)
    .run();

  const conversation = await env.DB.prepare(
    'SELECT user_a_id, user_b_id FROM conversations WHERE id = ?',
  )
    .bind(conversationId)
    .first<{ user_a_id: string; user_b_id: string }>();

  const room = env.CHAT_ROOM.get(env.CHAT_ROOM.idFromName(conversationId));
  await room.fetch(
    new Request('https://internal/broadcast', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        events: ids.map((messageId) => ({
          type: 'message_deleted',
          messageId,
          conversationId,
        })),
      }),
    }),
  );

  if (conversation) {
    await notifyInboxes(env, [conversation.user_a_id, conversation.user_b_id], () => [
      { type: 'conversation_refresh', conversationId },
    ]);
  }
}
