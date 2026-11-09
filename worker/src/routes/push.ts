import { IRequest, Router } from 'itty-router';
import { z } from 'zod';
import type { Env, AuthenticatedRequest } from '../types.js';
import { authMiddleware } from '../middleware/auth.js';
import { generateId } from '../utils/crypto.js';
import { readJsonBody } from '../utils/http.js';
import { MAX_PUSH_TOKENS_PER_USER } from '../services/push.js';

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

    const bodyResult = await readJsonBody(request);
    if (!bodyResult.ok) return bodyResult.response;
    const body = bodyResult.body;

    const parsed = registerPushTokenSchema.safeParse(body);
    if (!parsed.success) {
      return json({ error: 'Validation failed', details: parsed.error.flatten() }, 400);
    }

    const { token } = parsed.data;
    const platform = parsed.data.platform ?? 'android';
    const now = Math.floor(Date.now() / 1000);

    // Token is unique per install; a re-registration (or a different account
    // signing in on the same device) reassigns ownership. The cap is enforced
    // in the same statement so parallel registrations cannot overshoot it.
    const registered = await env.DB.prepare(
      `INSERT INTO push_tokens (id, user_id, token, platform, created_at, updated_at)
       SELECT ?, ?, ?, ?, ?, ?
       WHERE (SELECT COUNT(*) FROM push_tokens WHERE user_id = ?) < ?
          OR EXISTS (SELECT 1 FROM push_tokens WHERE token = ? AND user_id = ?)
       ON CONFLICT(token) DO UPDATE SET
         user_id = excluded.user_id,
         platform = excluded.platform,
         updated_at = excluded.updated_at`,
    )
      .bind(
        generateId(),
        userId,
        token,
        platform,
        now,
        now,
        userId,
        MAX_PUSH_TOKENS_PER_USER,
        token,
        userId,
      )
      .run();

    if (registered.meta.changes === 0) {
      return json(
        {
          error: 'push_token_limit_reached',
          message: `An account may register at most ${MAX_PUSH_TOKENS_PER_USER} push tokens`,
          limit: MAX_PUSH_TOKENS_PER_USER,
        },
        409,
      );
    }

    return json({ ok: true });
  },
);

pushRouter.post(
  '/unregister',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;

    const bodyResult = await readJsonBody(request);
    if (!bodyResult.ok) return bodyResult.response;
    const body = bodyResult.body;

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
