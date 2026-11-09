import { beforeEach, describe, expect, it } from 'vitest';
import {
  checkRateLimit,
  checkRateLimitDistributed,
  rateLimitMiddleware,
} from '../src/middleware/rateLimit.js';
import { countRows, db, resetDatabase, testEnv } from './support.js';

beforeEach(async () => {
  await resetDatabase();
});

describe('checkRateLimit (isolate-local)', () => {
  it('allows exactly the configured limit inside one window', () => {
    const key = `local:${crypto.randomUUID()}`;

    expect(checkRateLimit(key, { limit: 3, windowMs: 60_000 })).toBe(true);
    expect(checkRateLimit(key, { limit: 3, windowMs: 60_000 })).toBe(true);
    expect(checkRateLimit(key, { limit: 3, windowMs: 60_000 })).toBe(true);
    expect(checkRateLimit(key, { limit: 3, windowMs: 60_000 })).toBe(false);
  });

  it('starts a fresh window once the previous one elapses', async () => {
    const key = `local:${crypto.randomUUID()}`;
    expect(checkRateLimit(key, { limit: 1, windowMs: 5 })).toBe(true);
    expect(checkRateLimit(key, { limit: 1, windowMs: 5 })).toBe(false);
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(checkRateLimit(key, { limit: 1, windowMs: 5 })).toBe(true);
  });
});

describe('rateLimitMiddleware', () => {
  it('scopes buckets by method and path so a cheap route cannot drain another', () => {
    const ip = `ip-${crypto.randomUUID()}`;
    const middleware = rateLimitMiddleware({ limit: 1, windowMs: 60_000 });
    const request = (method: string, path: string) =>
      new Request(`https://example.com${path}`, {
        method,
        headers: { 'CF-Connecting-IP': ip },
      });

    expect(middleware(request('GET', '/api/a'))).toBeUndefined();
    expect(middleware(request('GET', '/api/a'))?.status).toBe(429);
    expect(middleware(request('POST', '/api/a'))).toBeUndefined();
    expect(middleware(request('GET', '/api/b'))).toBeUndefined();
  });
});

describe('checkRateLimitDistributed', () => {
  it('allows exactly the configured limit and denies the next request', async () => {
    const key = `dist:${crypto.randomUUID()}`;

    await expect(
      checkRateLimitDistributed(testEnv, key, { limit: 2, windowMs: 60_000 }),
    ).resolves.toBe(true);
    await expect(
      checkRateLimitDistributed(testEnv, key, { limit: 2, windowMs: 60_000 }),
    ).resolves.toBe(true);
    await expect(
      checkRateLimitDistributed(testEnv, key, { limit: 2, windowMs: 60_000 }),
    ).resolves.toBe(false);

    expect(
      await countRows('SELECT count AS n FROM rate_limit_buckets WHERE key = ?', key),
    ).toBe(2);
  });

  it('canonicalises concurrent claims to the limit', async () => {
    const key = `dist:${crypto.randomUUID()}`;

    const results = await Promise.all(
      Array.from({ length: 8 }, () =>
        checkRateLimitDistributed(testEnv, key, { limit: 3, windowMs: 60_000 }),
      ),
    );

    expect(results.filter(Boolean)).toHaveLength(3);
    expect(
      await countRows('SELECT count AS n FROM rate_limit_buckets WHERE key = ?', key),
    ).toBe(3);
  });

  it('resets the counter in a new window', async () => {
    const key = `dist:${crypto.randomUUID()}`;
    const windowMs = 60_000;
    const currentWindow = Math.floor(Date.now() / windowMs) * windowMs;
    await db
      .prepare('INSERT INTO rate_limit_buckets (key, window_start, count) VALUES (?, ?, ?)')
      .bind(key, currentWindow - windowMs, 99)
      .run();

    await expect(
      checkRateLimitDistributed(testEnv, key, { limit: 2, windowMs }),
    ).resolves.toBe(true);

    expect(
      await countRows('SELECT count AS n FROM rate_limit_buckets WHERE key = ?', key),
    ).toBe(1);
    expect(
      await countRows(
        'SELECT window_start AS n FROM rate_limit_buckets WHERE key = ?',
        key,
      ),
    ).toBe(currentWindow);
  });
});
