import type { Env } from '../types.js';
import { runBatched } from '../utils/d1.js';

// Deletes expired R2 media + rows and prunes old usage rows (scheduled handler).
const MAX_EXPIRED_MEDIA_PER_RUN = 200;
const MAX_DAILY_USAGE_PRUNE_PER_RUN = 1_000;

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
    const outcomes = await Promise.allSettled(rows.map((row) => env.MEDIA.delete(row.r2_key)));
    const removed = rows.filter((_, index) => outcomes[index]?.status === 'fulfilled');
    const retry = rows.filter((_, index) => outcomes[index]?.status === 'rejected');
    if (removed.length > 0) {
      await runBatched(
        db,
        removed.map((row) => db.prepare('DELETE FROM media WHERE id = ?').bind(row.id)),
      );
    }
    if (retry.length > 0) {
      // Mark inaccessible and move the retry deadline forward so repeated R2
      // failures cannot monopolize the first 200 rows on every hourly sweep.
      const retryAt = now + 3_600;
      await runBatched(
        db,
        retry.map((row) => db.prepare(
          `UPDATE media SET consumed = 1, expires_at = ? WHERE id = ?`,
        ).bind(retryAt, row.id)),
      );
    }
  }

  // Prune usage rows older than 30 days.
  await db
    .prepare(
      `DELETE FROM daily_usage
       WHERE rowid IN (
         SELECT rowid FROM daily_usage
         WHERE day < date('now', '-30 days')
         ORDER BY day ASC
         LIMIT ?
       )`,
    )
    .bind(MAX_DAILY_USAGE_PRUNE_PER_RUN)
    .run();
}
