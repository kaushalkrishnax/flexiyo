interface RateLimitEntry {
  count: number;
  windowStart: number;
}

const store = new Map<string, RateLimitEntry>();

export interface RateLimitOptions {
  limit?: number;
  windowMs?: number;
}

export function checkRateLimit(
  identifier: string,
  options: RateLimitOptions = {},
): boolean {
  const limit = options.limit ?? 20;
  const windowMs = options.windowMs ?? 60_000;
  const now = Date.now();

  const entry = store.get(identifier);

  if (!entry || now - entry.windowStart > windowMs) {
    store.set(identifier, { count: 1, windowStart: now });
    return true;
  }

  if (entry.count >= limit) {
    return false;
  }

  entry.count++;
  return true;
}

export function rateLimitMiddleware(
  options: RateLimitOptions = {},
): (request: Request) => Response | undefined {
  return (request: Request): Response | undefined => {
    const ip =
      request.headers.get('CF-Connecting-IP') ||
      request.headers.get('X-Forwarded-For') ||
      'unknown';

    const allowed = checkRateLimit(ip, options);
    if (!allowed) {
      return new Response(
        JSON.stringify({ error: 'Too many requests. Please slow down.' }),
        {
          status: 429,
          headers: {
            'Content-Type': 'application/json',
            'Retry-After': String(Math.ceil((options.windowMs ?? 60_000) / 1000)),
          },
        },
      );
    }
    return undefined;
  };
}

/**
 * Distributed (D1-backed) sliding-window limiter. Use for sensitive
 * endpoints (key bundles, auth) where isolate-local counters are ineffective.
 * Best-effort under concurrency; Cloudflare Rate Limiting bindings are the
 * preferred production solution for high-volume endpoints.
 */
export async function checkRateLimitDistributed(
  env: { DB: D1Database },
  identifier: string,
  options: RateLimitOptions = {},
): Promise<boolean> {
  const limit = options.limit ?? 20;
  const windowMs = options.windowMs ?? 60_000;
  const now = Date.now();
  const windowStart = Math.floor(now / windowMs) * windowMs;

  const row = await env.DB.prepare(
    `SELECT window_start, count FROM rate_limit_buckets WHERE key = ?`,
  )
    .bind(identifier)
    .first<{ window_start: number; count: number }>();

  if (!row || row.window_start !== windowStart) {
    await env.DB.prepare(
      `INSERT INTO rate_limit_buckets (key, window_start, count)
       VALUES (?, ?, 1)
       ON CONFLICT(key) DO UPDATE SET window_start = excluded.window_start, count = 1`,
    )
      .bind(identifier, windowStart)
      .run();
    return true;
  }

  if (row.count >= limit) {
    return false;
  }

  await env.DB.prepare(
    `UPDATE rate_limit_buckets SET count = count + 1 WHERE key = ?`,
  )
    .bind(identifier)
    .run();
  return true;
}
