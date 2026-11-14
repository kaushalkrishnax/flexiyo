import type { Env, JWTPayload } from '../types.js';
import { verifyJWT } from '../utils/jwt.js';
import { getSqlDb } from '../database/turso.js';

export async function authMiddleware(
  request: Request,
  env: Env,
): Promise<Response | undefined> {
  const authHeader = request.headers.get('Authorization');
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return new Response(JSON.stringify({ error: 'Missing or malformed Authorization header' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const token = authHeader.slice(7);

  let payload: Record<string, unknown> | null;
  try {
    payload = await verifyJWT(token, env.JWT_SECRET);
  } catch {
    payload = null;
  }

  if (!payload) {
    return new Response(JSON.stringify({ error: 'Invalid or expired token' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const jti = payload['jti'] as string | undefined;
  if (jti) {
    const db = getSqlDb(env, request);
    const revoked = await db.prepare(
      'SELECT jti FROM token_revocations WHERE jti = ?',
    )
      .bind(jti)
      .first<{ jti: string }>();

    if (revoked) {
      return new Response(JSON.stringify({ error: 'Token has been revoked' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      });
    }
  }

  (request as unknown as Record<string, unknown>)['user'] = payload as unknown as JWTPayload;
  return undefined;
}
