import { Router } from 'itty-router';
import { authRouter } from './routes/auth.js';
import { conversationsRouter } from './routes/conversations.js';
import { devicesRouter } from './routes/devices.js';
import { messagesRouter } from './routes/messages.js';
import { usersRouter } from './routes/users.js';
import { updateRouter } from './routes/update.js';
import { handlePreflight, withCors } from './middleware/cors.js';
import { cleanExpiredMessages } from './services/expiry.js';
import { ChatRoom } from './sockets/chatRoom.js';
import type { Env } from './types.js';
import { verifyJWT } from './utils/jwt.js';

const router = Router();

router.get('/health', () => new Response(JSON.stringify({ ok: true }), {
  status: 200,
  headers: { 'Content-Type': 'application/json' },
}));

router.get('/api/health', () => new Response(JSON.stringify({ ok: true }), {
  status: 200,
  headers: { 'Content-Type': 'application/json' },
}));

const routers = [authRouter, usersRouter, conversationsRouter, messagesRouter, devicesRouter, updateRouter];

export default {
  async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    if (request.method === 'OPTIONS') {
      return handlePreflight(env);
    }

    // WebSocket upgrade: GET /api/ws/:conversationId?token=<jwt>
    const url = new URL(request.url);
    const wsMatch = url.pathname.match(/^\/api\/ws\/([^/]+)$/);
    if (wsMatch && request.headers.get('Upgrade')?.toLowerCase() === 'websocket') {
      const conversationId = wsMatch[1];
      const token = url.searchParams.get('token');

      if (!token) {
        return new Response(JSON.stringify({ error: 'Missing token' }), {
          status: 401,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      const payload = await verifyJWT(token, env.JWT_SECRET);
      const userId = payload?.['sub'];
      if (typeof userId !== 'string') {
        return new Response(JSON.stringify({ error: 'Invalid or expired token' }), {
          status: 401,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      const conv = await env.DB.prepare(
        `SELECT id FROM conversations
         WHERE id = ? AND (user_a_id = ? OR user_b_id = ?)
           AND (request_status = 'accepted' OR initiated_by_id = ?)`,
      )
        .bind(conversationId, userId, userId, userId)
        .first<{ id: string }>();

      if (!conv) {
        return new Response(JSON.stringify({ error: 'Conversation not found' }), {
          status: 403,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      // Forward to the Durable Object for this conversation
      const doId = env.CHAT_ROOM.idFromName(conversationId);
      const stub = env.CHAT_ROOM.get(doId);

      // Forward request to the DO's /ws handler with the token in the query string
      const doRequest = new Request(
        `https://internal/ws?token=${encodeURIComponent(token)}`,
        {
          headers: request.headers,
          method: request.method,
        },
      );
      return stub.fetch(doRequest);
    }

    try {
      const healthResponse = await router.fetch(request, env, _ctx);
      if (healthResponse) {
        return withCors(healthResponse, env);
      }

      for (const routeHandler of routers) {
        const response = await routeHandler.fetch(request, env, _ctx);
        if (response) {
          return withCors(response, env);
        }
      }
    } catch (error) {
      console.error('Worker request failed', error);
      return withCors(
        new Response(JSON.stringify({ error: 'Internal server error' }), {
          status: 500,
          headers: { 'Content-Type': 'application/json' },
        }),
        env,
      );
    }

    return withCors(
      new Response(JSON.stringify({ error: 'Not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      }),
      env,
    );
  },

  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    await cleanExpiredMessages(env.DB);
  },
};

export { ChatRoom };
export { router };
