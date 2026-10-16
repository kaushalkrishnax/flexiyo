import type { Env, DOEvent } from '../types.js';
import { verifyJWT } from '../utils/jwt.js';
import type { JWTPayload } from '../types.js';

export class ChatRoom {
  private sessions: Map<string, WebSocket> = new Map();

  private env: Env;

  constructor(_state: DurableObjectState, env: Env) {
    void _state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === '/ws') {
      return this.handleWebSocket(request);
    }

    if (url.pathname === '/broadcast' && request.method === 'POST') {
      return this.handleBroadcast(request);
    }

    return new Response('Not found', { status: 404 });
  }

  private async handleWebSocket(request: Request): Promise<Response> {
    const upgradeHeader = request.headers.get('Upgrade');
    if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
      return new Response('Expected WebSocket upgrade', { status: 426 });
    }

    // Authenticate via ?token= query param (headers not available post-upgrade)
    const url = new URL(request.url);
    const token = url.searchParams.get('token');

    if (!token) {
      return new Response(
        JSON.stringify({ error: 'Missing token query parameter' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } },
      );
    }

    let payload: Record<string, unknown> | null;
    try {
      payload = await verifyJWT(token, this.env.JWT_SECRET);
    } catch {
      payload = null;
    }

    if (!payload) {
      return new Response(
        JSON.stringify({ error: 'Invalid or expired token' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } },
      );
    }

    // Check token revocation
    const jwtPayload = payload as unknown as JWTPayload;
    if (jwtPayload.jti) {
      const revoked = await this.env.DB.prepare(
        'SELECT jti FROM token_revocations WHERE jti = ?',
      )
        .bind(jwtPayload.jti)
        .first<{ jti: string }>();

      if (revoked) {
        return new Response(
          JSON.stringify({ error: 'Token has been revoked' }),
          { status: 401, headers: { 'Content-Type': 'application/json' } },
        );
      }
    }

    const userId = jwtPayload.sub;

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair) as [WebSocket, WebSocket];

    server.accept();

    const existingSession = this.sessions.get(userId);
    if (existingSession) {
      try {
        existingSession.close(1000, 'Replaced by new connection');
      } catch {
        // ignore — already closed
      }
    }

    this.sessions.set(userId, server);

    server.addEventListener('message', (event: MessageEvent) => {
      this.handleClientMessage(userId, event.data as string);
    });

    server.addEventListener('close', () => {
      this.sessions.delete(userId);
    });

    server.addEventListener('error', () => {
      this.sessions.delete(userId);
    });

    server.send(JSON.stringify({ type: 'connected', userId }));

    return new Response(null, { status: 101, webSocket: client });
  }

  private async handleBroadcast(request: Request): Promise<Response> {
    let event: DOEvent;
    try {
      event = await request.json() as DOEvent;
    } catch {
      return new Response('Invalid JSON', { status: 400 });
    }

    this.broadcast(event);
    return new Response(JSON.stringify({ delivered: this.sessions.size }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  broadcast(event: DOEvent): void {
    const message = JSON.stringify(event);
    const dead: string[] = [];

    for (const [userId, ws] of this.sessions.entries()) {
      try {
        ws.send(message);
      } catch {
        dead.push(userId);
      }
    }

    for (const userId of dead) {
      this.sessions.delete(userId);
    }
  }

  private handleClientMessage(userId: string, data: string): void {
    let msg: { type?: string; messageId?: string } | null = null;
    try {
      msg = JSON.parse(data) as { type?: string; messageId?: string };
    } catch {
      return;
    }

    if (msg?.type === 'delivery_ack' && msg.messageId) {
        void this.handleDeliveryAck(userId, msg.messageId);
    }

    if (msg?.type === 'typing_start' || msg?.type === 'typing_stop') {
      const typingEvent = JSON.stringify({ type: msg.type, userId });
      for (const [peerId, ws] of this.sessions.entries()) {
        if (peerId !== userId) {
          try {
            ws.send(typingEvent);
          } catch {
            // ignore send errors for dead sessions
          }
        }
      }
    }
  }

  private async handleDeliveryAck(recipientId: string, messageId: string): Promise<void> {
    const now = Math.floor(Date.now() / 1000);
    try {
      const message = await this.env.DB.prepare(
        'SELECT sender_id FROM messages WHERE id = ?',
      )
        .bind(messageId)
        .first<{ sender_id: string }>();
      if (!message || message.sender_id === recipientId) return;

      await this.env.DB.prepare(
        `UPDATE message_deliveries
         SET delivered_at = COALESCE(delivered_at, ?)
         WHERE message_id = ?
           AND recipient_device_id IN (SELECT id FROM devices WHERE user_id = ?)
           AND delivered_at IS NULL`,
      )
        .bind(now, messageId, recipientId)
        .run();

      this.sendToUser(message.sender_id, {
        type: 'message_delivered',
        messageId,
        recipientId,
        deliveredAt: now,
      });
    } catch (error) {
      console.error('Delivery acknowledgement failed', error);
    }
  }

  private sendToUser(userId: string, event: Record<string, unknown>): void {
    const session = this.sessions.get(userId);
    if (!session) return;
    try {
      session.send(JSON.stringify(event));
    } catch {
      this.sessions.delete(userId);
    }
  }

}
