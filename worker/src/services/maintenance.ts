import type { Env } from '../types.js';

const PRUNE_LIMIT = 1000;

/** Bounded cleanup of auth and rate-limit bookkeeping that has expired. */
export async function pruneOperationalData(env: Env): Promise<void> {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const bucketCutoff = Date.now() - 60 * 60 * 1000;

  await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM token_revocations WHERE jti IN (
         SELECT jti FROM token_revocations WHERE expires_at <= ? LIMIT ?
       )`,
    ).bind(nowSeconds, PRUNE_LIMIT),
    env.DB.prepare(
      `DELETE FROM rate_limit_buckets WHERE key IN (
         SELECT key FROM rate_limit_buckets WHERE window_start < ? LIMIT ?
       )`,
    ).bind(bucketCutoff, PRUNE_LIMIT),
    env.DB.prepare(
      `DELETE FROM email_verification_codes WHERE id IN (
         SELECT id FROM email_verification_codes WHERE expires_at <= ? LIMIT ?
       )`,
    ).bind(nowSeconds, PRUNE_LIMIT),
    // Keep terminal pairing state briefly for clients to observe it, then
    // remove expired rows so abandoned sessions cannot accumulate forever.
    env.DB.prepare(
      `DELETE FROM pairing_sessions WHERE id IN (
         SELECT id FROM pairing_sessions WHERE expires_at <= ? LIMIT ?
       )`,
    ).bind(nowSeconds - 86_400, PRUNE_LIMIT),
  ]);
}
