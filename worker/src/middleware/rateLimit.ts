interface RateLimitEntry {
  count: number;
  windowStart: number;
}

const store = new Map<string, RateLimitEntry>();

const STORE_MAX_AGE_MS = 60 * 60 * 1000;
let lastSweep = 0;

export interface RateLimitOptions {
  limit?: number;
  windowMs?: number;
}

function clientIp(request: Request): string {
  return (
    request.headers.get('CF-Connecting-IP') ||
    request.headers.get('X-Forwarded-For')?.split(',')[0]?.trim() ||
    'unknown'
  );
}

function sweepExpired(now: number): void {
  if (now - lastSweep < 60_000) return;
  lastSweep = now;
  for (const [key, entry] of store) {
    if (now - entry.windowStart > STORE_MAX_AGE_MS) store.delete(key);
  }
}

export function checkRateLimit(
  identifier: string,
  options: RateLimitOptions = {},
): boolean {
  const limit = options.limit ?? 20;
  const windowMs = options.windowMs ?? 60_000;
  const now = Date.now();

  sweepExpired(now);

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
    const url = new URL(request.url);
    // One bucket per method+route: a flood on a cheap endpoint must not spend
    // the budget of a sensitive one that shares the same client IP.
    const identifier = `${request.method}:${url.pathname}:${clientIp(request)}`;

    const allowed = checkRateLimit(identifier, options);
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
 * Distributed (D1-backed) fixed-window limiter. Use for sensitive endpoints
 * (key bundles, auth) where isolate-local counters are ineffective. The
 * read-and-increment is a single UPSERT so concurrent requests cannot all
 * observe the same below-limit count.
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

  const claimed = await env.DB.prepare(
    `INSERT INTO rate_limit_buckets (key, window_start, count)
     VALUES (?, ?, 1)
     ON CONFLICT(key) DO UPDATE SET
       count = CASE
         WHEN rate_limit_buckets.window_start = excluded.window_start
           THEN rate_limit_buckets.count + 1
         ELSE 1
       END,
       window_start = excluded.window_start
     WHERE rate_limit_buckets.window_start <> excluded.window_start
        OR rate_limit_buckets.count < ?
     RETURNING count`,
  )
    .bind(identifier, windowStart, limit)
    .first<{ count: number }>();

  return claimed != null;
}
