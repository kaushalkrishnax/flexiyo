import { IRequest, Router } from 'itty-router';
import { eq } from 'drizzle-orm';
import { z } from 'zod';
import { getDb } from '../database/db.js';
import { tokenRevocations, users } from '../database/schema.js';
import type { Env, AuthenticatedRequest, UserRow } from '../types.js';
import { hashPassword, verifyPassword, generateId } from '../utils/crypto.js';
import { signJWT } from '../utils/jwt.js';
import { authMiddleware } from '../middleware/auth.js';
import { rateLimitMiddleware } from '../middleware/rateLimit.js';

export const authRouter = Router({ base: '/api/auth' });

const registerSchema = z.object({
  username: z
    .string()
    .min(3, 'Username must be at least 3 characters')
    .max(30, 'Username must be at most 30 characters')
    .regex(/^[a-zA-Z0-9_]+$/, 'Username may only contain letters, numbers, and underscores'),
  password: z
    .string()
    .min(8, 'Password must be at least 8 characters')
    .max(128, 'Password must be at most 128 characters'),
});

const loginSchema = z.object({
  username: z.string().min(1),
  password: z.string().min(1),
});

authRouter.post(
  '/register',
  rateLimitMiddleware({ limit: 10, windowMs: 60_000 }),
  // @ts-ignore
  async (request: IRequest, env: Env, _ctx: ExecutionContext): Promise<Response> => {
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const parsed = registerSchema.safeParse(body);
    if (!parsed.success) {
      return new Response(
        JSON.stringify({ error: 'Validation failed', details: parsed.error.flatten() }),
        { status: 400, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const { username, password } = parsed.data;
    const db = getDb(env);

    // Check for existing username
    const existing = await db.select().from(users).where(eq(users.username, username)).limit(1).all();

    if (existing.length > 0) {
      return new Response(JSON.stringify({ error: 'Username already taken' }), {
        status: 409,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const userId = generateId();
    const passwordHash = await hashPassword(password);
    const now = Math.floor(Date.now() / 1000);

    await db.insert(users).values({
      id: userId,
      username,
      passwordHash,
      createdAt: now,
    }).run();

    const jti = generateId();
    const token = await signJWT(
      { sub: userId, username, jti },
      env.JWT_SECRET,
      604800, // 7 days
    );

    return new Response(
      JSON.stringify({
        token,
        user: { id: userId, username, createdAt: now },
      }),
      { status: 201, headers: { 'Content-Type': 'application/json' } },
    );
  },
);

authRouter.post(
  '/login',
  rateLimitMiddleware({ limit: 15, windowMs: 60_000 }),
  // @ts-ignore
  async (request: IRequest, env: Env, _ctx: ExecutionContext): Promise<Response> => {
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const parsed = loginSchema.safeParse(body);
    if (!parsed.success) {
      return new Response(
        JSON.stringify({ error: 'Validation failed', details: parsed.error.flatten() }),
        { status: 400, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const { username, password } = parsed.data;
    const db = getDb(env);

    const userRows = await db
      .select({
        id: users.id,
        username: users.username,
        password_hash: users.passwordHash,
        created_at: users.createdAt,
      })
      .from(users)
      .where(eq(users.username, username))
      .limit(1)
      .all();
    const user = userRows[0] as UserRow | undefined;

    if (!user) {
      // Perform a dummy hash to prevent timing attacks leaking whether the user exists
      await hashPassword(password);
      return new Response(JSON.stringify({ error: 'Invalid credentials' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const valid = await verifyPassword(password, user.password_hash);
    if (!valid) {
      return new Response(JSON.stringify({ error: 'Invalid credentials' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const jti = generateId();
    const token = await signJWT(
      { sub: user.id, username: user.username, jti },
      env.JWT_SECRET,
      604800,
    );

    return new Response(
      JSON.stringify({
        token,
        user: { id: user.id, username: user.username, createdAt: user.created_at },
      }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  },
);

authRouter.post(
  '/logout',
  // @ts-ignore
  (req: IRequest, env: Env, _ctx: ExecutionContext) => authMiddleware(req as unknown as Request, env),
  // @ts-ignore
  async (request: IRequest, env: Env, _ctx: ExecutionContext): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const { jti, exp, sub } = authReq.user;

    if (jti) {
      const db = getDb(env);
      await db.insert(tokenRevocations).values({
        jti,
        userId: sub,
        expiresAt: exp,
      }).onConflictDoNothing().run();
    }

    return new Response(JSON.stringify({ message: 'Logged out successfully' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  },
);

authRouter.get(
  '/me',
  // @ts-ignore
  (req: IRequest, env: Env, _ctx: ExecutionContext) => authMiddleware(req as unknown as Request, env),
  // @ts-ignore
  async (request: IRequest, env: Env, _ctx: ExecutionContext): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const { sub } = authReq.user;

    const db = getDb(env);
    const userRows = await db
      .select({
        id: users.id,
        username: users.username,
        created_at: users.createdAt,
      })
      .from(users)
      .where(eq(users.id, sub))
      .limit(1)
      .all();
    const user = userRows[0] as { id: string; username: string; created_at: number } | undefined;

    if (!user) {
      return new Response(JSON.stringify({ error: 'User not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    return new Response(
      JSON.stringify({ id: user.id, username: user.username, createdAt: user.created_at }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  },
);
