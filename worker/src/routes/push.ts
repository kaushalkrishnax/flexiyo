import { IRequest, Router } from 'itty-router';
import { z } from 'zod';
import type { Env, AuthenticatedRequest } from '../types.js';
import { authMiddleware } from '../middleware/auth.js';
import { generateId } from '../utils/crypto.js';

export const pushRouter = Router({ base: '/api/push' });

const registerPushTokenSchema = z.object({
  token: z.string().min(1).max(4096),
  platform: z.enum(['android', 'ios']).optional(),
});

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

pushRouter.post(
  '/register',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return json({ error: 'Invalid JSON body' }, 400);
    }

    const parsed = registerPushTokenSchema.safeParse(body);
    if (!parsed.success) {
      return json({ error: 'Validation failed', details: parsed.error.flatten() }, 400);
    }

    const { token } = parsed.data;
    const platform = parsed.data.platform ?? 'android';
    const now = Math.floor(Date.now() / 1000);

    // Token is unique per install; a re-registration (or a different account
    // signing in on the same device) reassigns ownership.
    await env.DB.prepare(
      `INSERT INTO push_tokens (id, user_id, token, platform, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(token) DO UPDATE SET
         user_id = excluded.user_id,
         platform = excluded.platform,
         updated_at = excluded.updated_at`,
    )
      .bind(generateId(), userId, token, platform, now, now)
      .run();

    return json({ ok: true });
  },
);

pushRouter.post(
  '/unregister',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return json({ error: 'Invalid JSON body' }, 400);
    }

    const token = (body as { token?: unknown } | null)?.token;
    if (typeof token !== 'string' || token.length === 0) {
      return json({ error: 'token is required' }, 400);
    }

    await env.DB.prepare(
      'DELETE FROM push_tokens WHERE token = ? AND user_id = ?',
    )
      .bind(token, userId)
      .run();

    return json({ ok: true });
  },
);
