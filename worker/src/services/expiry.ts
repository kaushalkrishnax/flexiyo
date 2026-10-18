import type { Env } from '../types.js';
import { deleteMessages } from './message_deletion.js';

const CLEANUP_INTERVAL_SECONDS = 60;

const MAX_EXPIRED_PER_RUN = 500;

export async function cleanExpiredMessages(env: Env): Promise<void> {
  const db = env.DB;
  const now = Math.floor(Date.now() / 1000);

  const lastCleanup = await db
    .prepare(`SELECT value FROM worker_meta WHERE key = 'last_expiry_cleanup'`)
    .first<{ value: string }>();

  const lastCleanupTs = lastCleanup ? parseInt(lastCleanup.value, 10) : 0;

  if (now - lastCleanupTs < CLEANUP_INTERVAL_SECONDS) {
    return;
  }

  const expired = await db
    .prepare(
      `SELECT id, conversation_id FROM messages
       WHERE expires_at IS NOT NULL AND expires_at <= ?
       ORDER BY expires_at ASC
       LIMIT ?`,
    )
    .bind(now, MAX_EXPIRED_PER_RUN)
    .all<{ id: string; conversation_id: string }>();

  const byConversation = new Map<string, string[]>();
  for (const message of expired.results ?? []) {
    const ids = byConversation.get(message.conversation_id) ?? [];
    ids.push(message.id);
    byConversation.set(message.conversation_id, ids);
  }
  for (const [conversationId, ids] of byConversation) {
    await deleteMessages(env, conversationId, ids);
  }

  await db
    .prepare(
      `INSERT INTO worker_meta (key, value)
       VALUES ('last_expiry_cleanup', ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    )
    .bind(String(now))
    .run();
}
