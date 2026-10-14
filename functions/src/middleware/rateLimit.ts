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

export function pruneRateLimitStore(windowMs = 60_000): void {
  const now = Date.now();
  for (const [key, entry] of store.entries()) {
    if (now - entry.windowStart > windowMs * 2) {
      store.delete(key);
    }
  }
}
