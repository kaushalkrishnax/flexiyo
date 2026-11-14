import type { Env } from '../types.js';
import { getSqlDb } from '../database/turso.js';

const PRUNE_LIMIT = 1000;

export async function pruneOperationalData(env: Env): Promise<void> {
  const db = getSqlDb(env);
  const nowSeconds = Math.floor(Date.now() / 1000);
  const bucketCutoff = Date.now() - 60 * 60 * 1000;

  await db.batch([
    db.prepare(
      `DELETE FROM token_revocations WHERE jti IN (
         SELECT jti FROM token_revocations WHERE expires_at <= ? LIMIT ?
       )`,
    ).bind(nowSeconds, PRUNE_LIMIT),
    db.prepare(
      `DELETE FROM rate_limit_buckets WHERE key IN (
         SELECT key FROM rate_limit_buckets WHERE window_start < ? LIMIT ?
       )`,
    ).bind(bucketCutoff, PRUNE_LIMIT),
    db.prepare(
      `DELETE FROM email_verification_codes WHERE id IN (
         SELECT id FROM email_verification_codes WHERE expires_at <= ? LIMIT ?
       )`,
    ).bind(nowSeconds, PRUNE_LIMIT),
    db.prepare(
      `DELETE FROM pairing_sessions WHERE id IN (
         SELECT id FROM pairing_sessions WHERE expires_at <= ? LIMIT ?
       )`,
    ).bind(nowSeconds - 86_400, PRUNE_LIMIT),
  ]);
}
