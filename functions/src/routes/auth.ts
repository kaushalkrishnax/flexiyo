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
    .regex(/^[a-zA-Z0-9_.]+$/, 'Username may only contain letters, numbers, underscores, and dots'),
  password: z
    .string()
    .min(8, 'Password must be at least 8 characters')
    .max(128, 'Password must be at most 128 characters'),
  email: z.string().email().optional(),
});

const loginSchema = z.object({
  username: z.string().min(1),
  password: z.string().min(1),
});

const googleAuthSchema = z.object({
  idToken: z.string().optional(),
  email: z.string().email().optional(),
  googleId: z.string().optional(),
  name: z.string().optional(),
  photoUrl: z.string().optional(),
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

authRouter.get(
  '/check-username',
  rateLimitMiddleware({ limit: 60, windowMs: 60_000 }),
  // @ts-ignore
  async (request: IRequest, env: Env, _ctx: ExecutionContext): Promise<Response> => {
    const url = new URL(request.url);
    const username = (url.searchParams.get('username') || '').trim();

    if (!username) {
      return new Response(JSON.stringify({ available: false, error: 'Username is required' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    if (username.length < 3) {
      return new Response(
        JSON.stringify({ available: false, message: 'Username must be at least 3 characters.' }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    }

    if (username.length > 30) {
      return new Response(
        JSON.stringify({ available: false, message: 'Username must be at most 30 characters.' }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    }

    if (!/^[a-zA-Z0-9_.]+$/.test(username)) {
      return new Response(
        JSON.stringify({ available: false, message: 'Username may only contain letters, numbers, underscores, and dots.' }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const db = getDb(env);
    const existing = await db
      .select({ id: users.id })
      .from(users)
      .where(eq(users.username, username))
      .limit(1)
      .all();

    if (existing.length > 0) {
      return new Response(
        JSON.stringify({ available: false, message: `The username ${username} is not available.` }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    }

    return new Response(
      JSON.stringify({ available: true, message: 'Username is available' }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  },
);

const handleGoogleOAuth = async (request: IRequest, env: Env): Promise<Response> => {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const parsed = googleAuthSchema.safeParse(body);
  if (!parsed.success) {
    return new Response(
      JSON.stringify({ error: 'Validation failed', details: parsed.error.flatten() }),
      { status: 400, headers: { 'Content-Type': 'application/json' } },
    );
  }

  const { idToken, email, googleId, name } = parsed.data;
  let verifiedEmail = email?.toLowerCase();
  let verifiedGoogleId = googleId;
  let displayName = name;

  if (idToken) {
    try {
      const res = await fetch(`https://oauth2.googleapis.com/tokeninfo?id_token=${encodeURIComponent(idToken)}`);
      if (res.ok) {
        const tokenInfo = (await res.json()) as {
          email?: string;
          sub?: string;
          name?: string;
          email_verified?: string | boolean;
        };
        if (tokenInfo.email) verifiedEmail = tokenInfo.email.toLowerCase();
        if (tokenInfo.sub) verifiedGoogleId = tokenInfo.sub;
        if (tokenInfo.name && !displayName) displayName = tokenInfo.name;
      }
    } catch (err) {
      console.error('Google tokeninfo fetch error:', err);
    }
  }

  if (!verifiedEmail && !verifiedGoogleId) {
    return new Response(JSON.stringify({ error: 'Missing verified Google credentials' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const db = getDb(env);

  // Search existing user by googleId or email
  let existingUser: typeof users.$inferSelect | undefined;
  if (verifiedGoogleId) {
    const rows = await db.select().from(users).where(eq(users.googleId, verifiedGoogleId)).limit(1).all();
    existingUser = rows[0];
  }

  if (!existingUser && verifiedEmail) {
    const rows = await db.select().from(users).where(eq(users.email, verifiedEmail)).limit(1).all();
    existingUser = rows[0];
    if (existingUser && verifiedGoogleId && !existingUser.googleId) {
      await db.update(users).set({ googleId: verifiedGoogleId }).where(eq(users.id, existingUser.id)).run();
    }
  }

  const now = Math.floor(Date.now() / 1000);
  let userId: string;
  let username: string;

  if (existingUser) {
    userId = existingUser.id;
    username = existingUser.username;
  } else {
    // Generate clean username from name or email
    const base = (displayName || verifiedEmail?.split('@')[0] || 'user')
      .toLowerCase()
      .replace(/[^a-z0-9_.]/g, '')
      .slice(0, 15);
    const suffix = Math.floor(100000 + Math.random() * 900000);
    username = `${base}.${suffix}`;
    userId = generateId();

    await db.insert(users).values({
      id: userId,
      username,
      email: verifiedEmail || null,
      googleId: verifiedGoogleId || null,
      emailVerified: 1,
      passwordHash: '',
      createdAt: now,
    }).run();
  }

  const jti = generateId();
  const token = await signJWT(
    { sub: userId, username, jti },
    env.JWT_SECRET,
    604800,
  );

  return new Response(
    JSON.stringify({
      token,
      user: { id: userId, username, email: verifiedEmail, createdAt: now },
      isNewUser: !existingUser,
    }),
    { status: 200, headers: { 'Content-Type': 'application/json' } },
  );
};

authRouter.post(
  '/google',
  rateLimitMiddleware({ limit: 15, windowMs: 60_000 }),
  // @ts-ignore
  (req: IRequest, env: Env) => handleGoogleOAuth(req, env),
);

authRouter.post(
  '/oauth-callback',
  rateLimitMiddleware({ limit: 15, windowMs: 60_000 }),
  // @ts-ignore
  (req: IRequest, env: Env) => handleGoogleOAuth(req, env),
);

authRouter.post(
  '/email',
  // @ts-ignore
  (req: IRequest, env: Env, _ctx: ExecutionContext) => authMiddleware(req as unknown as Request, env),
  // @ts-ignore
  async (request: IRequest, env: Env, _ctx: ExecutionContext): Promise<Response> => {
    let body: any;
    try {
      body = await request.json();
    } catch {
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const email = (body.email || '').trim().toLowerCase();
    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return new Response(JSON.stringify({ error: 'Valid email address is required' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const authReq = request as unknown as AuthenticatedRequest;
    const db = getDb(env);

    const existing = await db
      .select({ id: users.id })
      .from(users)
      .where(eq(users.email, email))
      .limit(1)
      .all();

    if (existing.length > 0 && existing[0].id !== authReq.user.sub) {
      return new Response(JSON.stringify({ error: 'Email already registered with another account' }), {
        status: 409,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    await db.update(users).set({ email, emailVerified: 0 }).where(eq(users.id, authReq.user.sub)).run();

    return new Response(
      JSON.stringify({ message: 'Email saved successfully', email, verified: false }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  },
);

authRouter.post(
  '/email/verify',
  // @ts-ignore
  (req: IRequest, env: Env, _ctx: ExecutionContext) => authMiddleware(req as unknown as Request, env),
  // @ts-ignore
  async (request: IRequest, env: Env, _ctx: ExecutionContext): Promise<Response> => {
    let body: any;
    try {
      body = await request.json();
    } catch {
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const code = (body.code || '').trim();
    if (!code || code.length < 4) {
      return new Response(JSON.stringify({ error: 'Valid verification code is required' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const authReq = request as unknown as AuthenticatedRequest;
    const db = getDb(env);
    await db.update(users).set({ emailVerified: 1 }).where(eq(users.id, authReq.user.sub)).run();

    return new Response(
      JSON.stringify({ message: 'Email verified successfully', verified: true }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  },
);
