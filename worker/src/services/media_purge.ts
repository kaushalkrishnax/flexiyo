import type { Env } from '../types.js';

// Deletes expired R2 media + rows and prunes old usage rows (scheduled handler).
const MAX_EXPIRED_MEDIA_PER_RUN = 200;

export async function purgeExpiredMedia(db: D1Database, env: Env): Promise<void> {
  const now = Math.floor(Date.now() / 1000);

  // Bounded: each hourly run makes forward progress without an unbounded scan.
  const expired = await db
    .prepare(
      `SELECT id, r2_key FROM media WHERE expires_at < ?
       ORDER BY expires_at ASC
       LIMIT ?`,
    )
    .bind(now, MAX_EXPIRED_MEDIA_PER_RUN)
    .all<{ id: string; r2_key: string }>();

  const rows = expired.results ?? [];
  if (rows.length > 0) {
    for (const row of rows) {
      try {
        await env.MEDIA.delete(row.r2_key);
      } catch {}
    }
    await db.batch(rows.flatMap((row) => [
      db.prepare('DELETE FROM media_views WHERE media_id = ?').bind(row.id),
      db.prepare('DELETE FROM media WHERE id = ?').bind(row.id),
    ]));
  }

  // Prune usage rows older than 30 days.
  await db
    .prepare("DELETE FROM daily_usage WHERE day < date('now', '-30 days')")
    .run();
}
