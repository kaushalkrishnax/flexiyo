import type { Env } from '../types.js';

// Deletes expired R2 media + rows and prunes old usage rows (scheduled handler).
export async function purgeExpiredMedia(db: D1Database, env: Env): Promise<void> {
  const now = Math.floor(Date.now() / 1000);

  const expired = await db
    .prepare(
      'SELECT id, r2_key FROM media WHERE expires_at < ? AND consumed = 0',
    )
    .bind(now)
    .all<{ id: string; r2_key: string }>();

  for (const row of expired.results ?? []) {
    try {
      await env.MEDIA.delete(row.r2_key);
    } catch {}
    await db
      .prepare('DELETE FROM media_views WHERE media_id = ?')
      .bind(row.id)
      .run();
    await db.prepare('DELETE FROM media WHERE id = ?').bind(row.id).run();
  }

  // Prune usage rows older than 30 days.
  await db
    .prepare("DELETE FROM daily_usage WHERE day < date('now', '-30 days')")
    .run();
}
