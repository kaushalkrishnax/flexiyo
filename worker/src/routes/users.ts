import { IRequest, Router } from 'itty-router';
import { and, like, ne } from 'drizzle-orm';
import type { Env, AuthenticatedRequest } from '../types.js';
import { getDb } from '../database/db.js';
import { users } from '../database/schema.js';
import { authMiddleware } from '../middleware/auth.js';
import { rateLimitMiddleware } from '../middleware/rateLimit.js';

export const usersRouter = Router({ base: '/api/users' });

usersRouter.get(
  '/search',
  rateLimitMiddleware({ limit: 30, windowMs: 60_000 }),
  // @ts-ignore — itty-router v5 handler arity: auth middleware is (Request, Env)
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  // @ts-ignore — itty-router v5 handler arity
  async (request: IRequest, env: Env, _ctx: ExecutionContext): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const url = new URL(request.url);
    const q = url.searchParams.get('q') ?? '';

    if (!q || q.length < 1) {
      return new Response(JSON.stringify({ error: 'Search query "q" is required' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    if (q.length > 30) {
      return new Response(JSON.stringify({ error: 'Query too long' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const db = getDb(env);
    const pattern = `${q}%`;
    const rows = await db
      .select({ id: users.id, username: users.username })
      .from(users)
      .where(and(like(users.username, pattern), ne(users.id, authReq.user.sub)))
      .limit(20)
      .all();

    const results = rows;

    return new Response(JSON.stringify(results), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  },
);
