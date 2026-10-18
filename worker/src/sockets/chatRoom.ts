import type { Env, DOEvent } from '../types.js';
import { verifyJWT } from '../utils/jwt.js';
import type { JWTPayload } from '../types.js';

interface Session {
  id: string;
  userId: string;
  ws: WebSocket;
  typingCount: number;
  typingWindowStart: number;
}

const MAX_FRAME_BYTES = 64 * 1024;
const MAX_TYPING_PER_WINDOW = 20;
const TYPING_WINDOW_MS = 10_000;
const MAX_SESSIONS_PER_USER = 8;

export class ChatRoom {
  private sessions: Map<string, Session> = new Map();
  private userSessions: Map<string, Set<string>> = new Map();

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

    // Cap concurrent sessions per user to prevent connection leaks.
    const existing = this.userSessions.get(userId);
    if (existing && existing.size >= MAX_SESSIONS_PER_USER) {
      // Drop the oldest session for this user.
      const oldestId = existing.values().next().value;
      if (oldestId) {
        const old = this.sessions.get(oldestId);
        if (old) {
          try {
            old.ws.close(1000, 'Session limit reached');
          } catch {
            // ignore
          }
          this.removeSession(oldestId);
        }
      }
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair) as [WebSocket, WebSocket];

    server.accept();

    const sessionId = crypto.randomUUID();
    const session: Session = {
      id: sessionId,
      userId,
      ws: server,
      typingCount: 0,
      typingWindowStart: Date.now(),
    };

    this.sessions.set(sessionId, session);
    if (!this.userSessions.has(userId)) {
      this.userSessions.set(userId, new Set());
    }
    this.userSessions.get(userId)!.add(sessionId);

    server.addEventListener('message', (event: MessageEvent) => {
      const data = event.data;
      if (typeof data === 'string' && data.length > MAX_FRAME_BYTES) {
        try {
          server.close(1009, 'Frame too large');
        } catch {
          // ignore
        }
        this.removeSession(sessionId);
        return;
      }
      this.handleClientMessage(sessionId, data as string);
    });

    // Only remove THIS session on close/error, never a newer one.
    server.addEventListener('close', () => {
      this.removeSession(sessionId);
    });
    server.addEventListener('error', () => {
      this.removeSession(sessionId);
    });

    server.send(JSON.stringify({ type: 'connected', userId }));

    return new Response(null, { status: 101, webSocket: client });
  }

  private removeSession(sessionId: string): void {
    const session = this.sessions.get(sessionId);
    if (!session) return;
    this.sessions.delete(sessionId);
    const set = this.userSessions.get(session.userId);
    if (set) {
      set.delete(sessionId);
      if (set.size === 0) this.userSessions.delete(session.userId);
    }
  }

  private async handleBroadcast(request: Request): Promise<Response> {
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return new Response('Invalid JSON', { status: 400 });
    }

    // Support both a single event and a bounded batch of events.
    let events: DOEvent[] = [];
    if (Array.isArray((body as { events?: unknown })?.events)) {
      events = ((body as { events: DOEvent[] }).events ?? []).slice(0, 100);
    } else if (body && typeof body === 'object' && (body as { type?: unknown }).type) {
      events = [body as DOEvent];
    }

    let delivered = 0;
    for (const event of events) {
      delivered += this.broadcast(event);
    }

    return new Response(JSON.stringify({ delivered }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  /** Returns the number of sessions that received the event. */
  broadcast(event: DOEvent): number {
    const message = JSON.stringify(event);
    const dead: string[] = [];
    let count = 0;

    for (const session of this.sessions.values()) {
      try {
        session.ws.send(message);
        count++;
      } catch {
        dead.push(session.id);
      }
    }

    for (const id of dead) {
      this.removeSession(id);
    }

    return count;
  }

  private handleClientMessage(sessionId: string, data: string): void {
    const session = this.sessions.get(sessionId);
    if (!session) return;

    let msg: { type?: string; messageId?: string } | null = null;
    try {
      msg = JSON.parse(data) as { type?: string; messageId?: string };
    } catch {
      return;
    }
    if (!msg || typeof msg.type !== 'string') return;

    // Bound frame already enforced; validate event type.
    if (msg.type === 'delivery_ack' && typeof msg.messageId === 'string' && msg.messageId.length <= 128) {
      void this.handleDeliveryAck(session.userId, msg.messageId);
    }

    if (msg.type === 'typing_start' || msg.type === 'typing_stop') {
      // Per-connection typing flood protection.
      const now = Date.now();
      if (now - session.typingWindowStart > TYPING_WINDOW_MS) {
        session.typingCount = 0;
        session.typingWindowStart = now;
      }
      session.typingCount++;
      if (session.typingCount > MAX_TYPING_PER_WINDOW) return;

      const typingEvent = JSON.stringify({ type: msg.type, userId: session.userId });
      for (const peer of this.sessions.values()) {
        if (peer.userId !== session.userId) {
          try {
            peer.ws.send(typingEvent);
          } catch {
            // ignore
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
    const message = JSON.stringify(event);
    const set = this.userSessions.get(userId);
    if (!set) return;
    const dead: string[] = [];
    for (const id of set) {
      const session = this.sessions.get(id);
      if (!session) continue;
      try {
        session.ws.send(message);
      } catch {
        dead.push(id);
      }
    }
    for (const id of dead) {
      this.removeSession(id);
    }
  }
}
