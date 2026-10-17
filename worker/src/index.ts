import { Router } from 'itty-router';
import { authRouter } from './routes/auth.js';
import { conversationsRouter } from './routes/conversations.js';
import { devicesRouter } from './routes/devices.js';
import { messagesRouter } from './routes/messages.js';
import { mediaRouter } from './routes/media.js';
import { usersRouter } from './routes/users.js';
import { updateRouter } from './routes/update.js';
import { pushRouter } from './routes/push.js';
import { handlePreflight, withCors } from './middleware/cors.js';
import { cleanExpiredMessages } from './services/expiry.js';
import { purgeExpiredMedia } from './services/media_purge.js';
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

const routers = [authRouter, usersRouter, conversationsRouter, messagesRouter, mediaRouter, devicesRouter, updateRouter, pushRouter];

export default {
  async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    if (request.method === 'OPTIONS') {
      return handlePreflight(env, request);
    }

    const url = new URL(request.url);
    const inboxMatch = url.pathname === '/api/ws/inbox';
    const wsMatch = url.pathname.match(/^\/api\/ws\/([^/]+)$/);
    if ((inboxMatch || wsMatch) && request.headers.get('Upgrade')?.toLowerCase() === 'websocket') {
      const token = url.searchParams.get('token');

      if (!token) {
        return new Response(JSON.stringify({ error: 'Missing token' }), {
          status: 401,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      let payload: Record<string, unknown> | null;
      try {
        payload = await verifyJWT(token, env.JWT_SECRET);
      } catch (error) {
        console.error('WebSocket authentication failed', error);
        return new Response(JSON.stringify({ error: 'Invalid or expired token' }), {
          status: 401,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      const userId = payload?.['sub'];
      if (typeof userId !== 'string') {
        return new Response(JSON.stringify({ error: 'Invalid or expired token' }), {
          status: 401,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      if (inboxMatch) {
        const doId = env.CHAT_ROOM.idFromName(`inbox:${userId}`);
        const stub = env.CHAT_ROOM.get(doId);
        return stub.fetch(new Request(
          `https://internal/ws?token=${encodeURIComponent(token)}`,
          { headers: request.headers, method: request.method },
        ));
      }

      const conversationId = wsMatch![1];
      const conv = await env.DB.prepare(
        `SELECT id FROM conversations
         WHERE id = ? AND (user_a_id = ? OR user_b_id = ?)`,
      ).bind(conversationId, userId, userId).first<{ id: string }>();

      if (!conv) {
        return new Response(JSON.stringify({ error: 'Conversation not found' }), {
          status: 403,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      const doId = env.CHAT_ROOM.idFromName(conversationId);
      const stub = env.CHAT_ROOM.get(doId);

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
        return withCors(healthResponse, env, request);
      }

      for (const routeHandler of routers) {
        const response = await routeHandler.fetch(request, env, _ctx);
        if (response) {
          return withCors(response, env, request);
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
        request,
      );
    }

    return withCors(
      new Response(JSON.stringify({ error: 'Not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      }),
      env,
      request,
    );
  },

  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    await cleanExpiredMessages(env);
    await purgeExpiredMedia(env.DB, env);
  },
};

export { ChatRoom };
export { router };
