import type { Env, DOEvent } from '../types.js';
import { verifyJWT } from '../utils/jwt.js';
import { notifyInboxes } from '../services/inbox.js';
import type { JWTPayload } from '../types.js';

interface Session {
  id: string;
  userId: string;
  deviceId: number | null;
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

    let deviceId: number | null = null;
    const deviceIdParam = url.searchParams.get('deviceId');
    if (deviceIdParam) {
      const parsedDeviceId = Number(deviceIdParam);
      if (!Number.isInteger(parsedDeviceId) || parsedDeviceId <= 0) {
        return new Response(JSON.stringify({ error: 'Invalid device' }), { status: 400 });
      }
      const row = await this.env.DB.prepare(
        `SELECT id FROM devices WHERE id = ? AND user_id = ? AND status = 'active'`,
      )
        .bind(parsedDeviceId, userId)
        .first<{ id: number }>();
      if (!row) {
        return new Response(JSON.stringify({ error: 'Unknown or inactive device' }), { status: 403 });
      }
      deviceId = row.id;
    }

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
      deviceId,
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

    // Bounded batch of events.
    const events: DOEvent[] = Array.isArray((body as { events?: unknown })?.events)
      ? ((body as { events: DOEvent[] }).events ?? []).slice(0, 100)
      : [];

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

    let msg: { type?: string; messageId?: string; requestId?: string } | null = null;
    try {
      msg = JSON.parse(data) as { type?: string; messageId?: string; requestId?: string };
    } catch {
      try {
        session.ws.send(JSON.stringify({ type: 'error', code: 'invalid_json' }));
      } catch {
        // ignore
      }
      return;
    }
    if (!msg || typeof msg.type !== 'string') {
      try {
        session.ws.send(JSON.stringify({ type: 'error', code: 'invalid_event', requestId: msg?.requestId }));
      } catch {
        // ignore
      }
      return;
    }

    const requestId = typeof msg.requestId === 'string' ? msg.requestId : undefined;

    // Bound frame already enforced; validate event type.
    if (msg.type === 'delivery_ack' && typeof msg.messageId === 'string' && msg.messageId.length <= 128) {
      void this.handleDeliveryAck(session.userId, msg.messageId);
      if (requestId) {
        try {
          session.ws.send(JSON.stringify({ type: 'ack', requestId, ok: true }));
        } catch {
          // ignore
        }
      }
      return;
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
      return;
    }

    if (msg.type === 'ping') {
      try {
        session.ws.send(JSON.stringify({ type: 'pong', requestId }));
      } catch {
        // ignore
      }
      return;
    }

    if (msg.type === 'send_message') {
      void this.handleSendMessage(session, msg as Record<string, unknown>, requestId);
      return;
    }

    // Explicit error for unsupported/unknown events rather than silent drop.
    try {
      session.ws.send(JSON.stringify({
        type: 'error',
        requestId,
        code: 'unsupported_event',
        eventType: msg.type,
      }));
    } catch {
      // ignore
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

  async handleSendMessage(
    session: Session,
    msg: Record<string, unknown>,
    requestId?: string,
  ): Promise<void> {
    const sendAck = (payload: Record<string, unknown>) => {
      try {
        session.ws.send(JSON.stringify({ ...payload, requestId }));
      } catch {
        // ignore
      }
      if (payload.type === 'error') {
        console.warn(
          `send_message rejected user=${session.userId} device=${session.deviceId}: ${JSON.stringify(payload)}`,
        );
      }
    };

    try {
      await this.persistMessage(session, msg, sendAck);
    } catch (error) {
      console.error('WebSocket message send failed', error);
      sendAck({ type: 'error', code: 'send_failed', message: 'Message could not be sent' });
    }
  }

  private async persistMessage(
    session: Session,
    msg: Record<string, unknown>,
    sendAck: (payload: Record<string, unknown>) => void,
  ): Promise<void> {
    const userId = session.userId;
    const deviceId = session.deviceId;
    if (!deviceId) {
      sendAck({ type: 'error', code: 'device_required', message: 'Device registration required' });
      return;
    }

    const conversationId = typeof msg.conversationId === 'string' ? msg.conversationId : null;
    // The DO instance is per-conversation; allow client to override but validate.
    const targetConversationId = conversationId;
    if (!targetConversationId) {
      sendAck({ type: 'error', code: 'invalid_conversation', message: 'conversationId required' });
      return;
    }

    const msgId = typeof msg.id === 'string' ? msg.id : null;
    if (!msgId) {
      sendAck({ type: 'error', code: 'invalid_message_id', message: 'id required' });
      return;
    }

    const recipientId = typeof msg.recipientId === 'string' ? msg.recipientId : null;
    const payloads = Array.isArray(msg.payloads) ? (msg.payloads as Array<unknown>) : [];
    const messageType = msg.messageType === 'prekey' ? 'prekey' : 'signal';
    const replyToId = typeof msg.replyToId === 'string' ? msg.replyToId : null;
    const mediaId = typeof msg.mediaId === 'string' ? msg.mediaId : null;

    // Validate conversation membership.
    const conv = await this.env.DB.prepare(
      `SELECT id, user_a_id, user_b_id FROM conversations WHERE id = ? AND (user_a_id = ? OR user_b_id = ?)`,
    )
      .bind(targetConversationId, userId, userId)
      .first<{ id: string; user_a_id: string; user_b_id: string }>();
    if (!conv) {
      sendAck({ type: 'error', code: 'forbidden', message: 'Conversation not found' });
      return;
    }
    const expectedRecipient = conv.user_a_id === userId ? conv.user_b_id : conv.user_a_id;
    if (recipientId !== expectedRecipient) {
      sendAck({ type: 'error', code: 'invalid_recipient', message: 'Invalid recipientId' });
      return;
    }

    const conversationState = await this.env.DB.prepare(
      'SELECT request_status, initiated_by_id FROM conversations WHERE id = ?',
    )
      .bind(targetConversationId)
      .first<{ request_status: string; initiated_by_id: string }>();
    if (conversationState) {
      const blockRow = await this.env.DB.prepare(
        `SELECT 1 FROM user_blocks
         WHERE (blocker_id = ? AND blocked_id = ?)
            OR (blocker_id = ? AND blocked_id = ?)
         LIMIT 1`,
      )
        .bind(userId, expectedRecipient, expectedRecipient, userId)
        .first();
      if (blockRow) {
        sendAck({ type: 'error', code: 'blocked', message: 'Messaging is blocked for this conversation' });
        return;
      }
      if (conversationState.request_status === 'pending' && conversationState.initiated_by_id !== userId) {
        sendAck({ type: 'error', code: 'request_pending', message: 'Accept the conversation before sending' });
        return;
      }
      if (conversationState.request_status === 'pending') {
        const prior = await this.env.DB.prepare(
          `SELECT id FROM messages WHERE conversation_id = ? AND sender_id = ? AND is_unsent = 0 LIMIT 1`,
        )
          .bind(targetConversationId, userId)
          .first<{ id: string }>();
        if (prior) {
          sendAck({ type: 'error', code: 'request_pending', message: 'Only one message may be sent with a pending request' });
          return;
        }
      }
    }

    // Idempotent retry.
    const existing = await this.env.DB.prepare(
      `SELECT id, sender_id, conversation_id FROM messages WHERE id = ?`,
    )
      .bind(msgId)
      .first<{ id: string; sender_id: string; conversation_id: string }>();
    if (existing) {
      if (existing.sender_id !== userId || existing.conversation_id !== targetConversationId) {
        sendAck({ type: 'error', code: 'conflict', message: 'Message id conflict' });
        return;
      }
      sendAck({ type: 'ack', ok: true, messageId: msgId, status: 'already_committed' });
      return;
    }

    const senderDevice = await this.env.DB.prepare(
      `SELECT id FROM devices WHERE id = ? AND user_id = ? AND status = 'active'`,
    )
      .bind(deviceId, userId)
      .first<{ id: number }>();
    if (!senderDevice) {
      sendAck({ type: 'error', code: 'device_required', message: 'Device registration required' });
      return;
    }

    const recipientDevices = (
      await this.env.DB.prepare(
        `SELECT id FROM devices WHERE user_id = ? AND status = 'active' ORDER BY id`,
      )
        .bind(recipientId)
        .all<{ id: number }>()
    ).results.map((r) => r.id);
    if (recipientDevices.length === 0) {
      sendAck({ type: 'error', code: 'no_recipient_device', message: "Recipient hasn't registered encryption keys yet." });
      return;
    }

    // Sender's own active devices (sender-device sync: each of the sender's
    // sibling installations gets a ciphertext it can decrypt).
    const senderDevices = (
      await this.env.DB.prepare(
        `SELECT id FROM devices WHERE user_id = ? AND status = 'active' ORDER BY id`,
      )
        .bind(userId)
        .all<{ id: number }>()
    ).results.map((r) => r.id);
    const allowedDevices = new Set([...recipientDevices, ...senderDevices]);

    // Validate payloads.
    const deviceIds = new Set<number>();
    for (const p of payloads) {
      if (!p || typeof p !== 'object') {
        sendAck({ type: 'error', code: 'invalid_payload', message: 'Invalid payload' });
        return;
      }
      const dp = p as Record<string, unknown>;
      const did = dp.deviceId;
      const ct = dp.ciphertext;
      if (typeof did !== 'number' || !Number.isInteger(did) || did <= 0) {
        sendAck({ type: 'error', code: 'invalid_device', message: 'Invalid deviceId' });
        return;
      }
      if (typeof ct !== 'string' || ct.length === 0) {
        sendAck({ type: 'error', code: 'missing_ciphertext', message: 'Missing ciphertext' });
        return;
      }
      if (ct.length > 64 * 1024) {
        sendAck({ type: 'error', code: 'oversized', message: 'Payload too large' });
        return;
      }
      if (deviceIds.has(did)) {
        sendAck({ type: 'error', code: 'duplicate_device', message: 'Duplicate deviceId' });
        return;
      }
      if (!allowedDevices.has(did)) {
        sendAck({ type: 'error', code: 'unknown_device', message: 'Unknown device', deviceId: did });
        return;
      }
      deviceIds.add(did);
    }
    // Every active recipient device must receive a ciphertext, otherwise a
    // device silently misses the message.
    const missingRecipient = recipientDevices.filter((id) => !deviceIds.has(id));
    if (missingRecipient.length > 0) {
      sendAck({ type: 'error', code: 'missing_device_payloads', message: 'Missing device payloads', missingDeviceIds: missingRecipient });
      return;
    }

    const now = Math.floor(Date.now() / 1000);

    await this.env.DB.prepare(
      `INSERT INTO messages
        (id, conversation_id, sender_id, sender_device_id, message_type, reply_to_id,
         media_id, version, is_unsent, created_at, expires_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?)`,
    )
      .bind(msgId, targetConversationId, userId, deviceId, messageType, replyToId, mediaId, now, null)
      .run();

    await this.env.DB.prepare(
      'UPDATE conversations SET last_message_at = ? WHERE id = ?',
    )
      .bind(now, targetConversationId)
      .run();

    const deliveryStmts = payloads.map((p) => {
      const dp = p as Record<string, unknown>;
      const did = dp.deviceId as number;
      const ct = dp.ciphertext as string;
      const mt = typeof dp.messageType === 'string' ? dp.messageType : messageType;
      return this.env.DB.prepare(
        `INSERT OR IGNORE INTO message_deliveries
           (id, message_id, recipient_device_id, sender_device_id, payload,
            message_type, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      ).bind(crypto.randomUUID(), msgId, did, deviceId, ct, mt, now);
    });
    if (deliveryStmts.length > 0) {
      await this.env.DB.batch(deliveryStmts);
    }

    const deliveryRows = payloads.map((p) => {
      const dp = p as Record<string, unknown>;
      return {
        deviceId: dp.deviceId as number,
        payload: dp.ciphertext as string,
        messageType: (typeof dp.messageType === 'string' ? dp.messageType : messageType),
      };
    });

    const event: DOEvent = {
      type: 'new_message',
      messageId: msgId,
      conversationId: targetConversationId,
      senderId: userId,
      senderDeviceId: deviceId,
      recipients: [userId, recipientId as string],
      payloads: deliveryRows.map((r) => ({
        deviceId: r.deviceId,
        payload: r.payload,
        messageType: r.messageType,
      })),
      messageType,
      replyToId: replyToId ?? null,
      createdAt: now,
      expiresAt: null,
    };

    this.broadcast(event);

    try {
      await notifyInboxes(this.env, [userId, recipientId as string], (targetUserId) => [{
        type: 'inbox_message',
        conversationId: targetConversationId,
        senderId: userId,
        preview: 'New message',
        lastMessageAt: now,
        isIncoming: targetUserId !== userId,
      }]);
    } catch {
      // ignore
    }

    sendAck({ type: 'ack', ok: true, messageId: msgId, status: 'sent' });
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
