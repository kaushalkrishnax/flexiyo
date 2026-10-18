import type { Env } from '../types.js';
import { notifyInboxes } from './inbox.js';

export async function deleteMessages(
  env: Env,
  conversationId: string,
  messageIds: string[],
): Promise<void> {
  const ids = [...new Set(messageIds)];
  if (ids.length === 0) return;

  await env.DB.batch(
    ids.map((messageId) =>
      env.DB.prepare(
        'DELETE FROM messages WHERE id = ? AND conversation_id = ?',
      ).bind(messageId, conversationId),
    ),
  );

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
