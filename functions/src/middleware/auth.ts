import type { Env, JWTPayload } from '../types.js';
import { verifyJWT } from '../utils/jwt.js';

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

  // Check token revocation list
  const jti = payload['jti'] as string | undefined;
  if (jti) {
    const revoked = await env.DB.prepare(
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

  // Attach to request (Workers Request is mutable via property assignment)
  (request as unknown as Record<string, unknown>)['user'] = payload as unknown as JWTPayload;
  return undefined; // continue to next handler
}
