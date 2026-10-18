import type { Env, DOEvent } from '../types.js';
import { verifyJWT } from '../utils/jwt.js';
import { notifyInboxes } from '../services/inbox.js';
import { pairedActiveDeviceIds } from '../middleware/device.js';
import type { JWTPayload } from '../types.js';

/**
 * Per-socket state. Kept serialized on the WebSocket itself so identity,
 * device routing and typing throttling survive hibernation and the in-memory
 * object being thrown away.
 */
interface SessionState {
  sessionId: string;
  userId: string;
  deviceId: number | null;
  connectedAt: number;
  typingCount: number;
  typingWindowStart: number;
}

interface Session extends SessionState {
  ws: WebSocket;
}

interface ConversationGateRow {
  user_a_id: string;
  user_b_id: string;
  request_status: string;
  initiated_by_id: string | null;
  is_blocked: number;
  message_exists: number;
  message_owned: number;
}

const MAX_FRAME_BYTES = 64 * 1024;
const MAX_TYPING_PER_WINDOW = 20;
const TYPING_WINDOW_MS = 10_000;
const MAX_SESSIONS_PER_USER = 8;
const SOCKET_OPEN = 1;

/**
 * Exact heartbeat frame the Flutter client sends. Matched by the runtime's
 * auto-response so a hibernating object is not woken just to echo a pong.
 */
const PING_FRAME = '{"type":"ping"}';
const PONG_FRAME = '{"type":"pong"}';

/**
 * Membership, request state, block state and the idempotency probe in a single
 * round trip. Binds: userId ×4 (block + recipient CASE), messageId, messageId,
 * userId, conversationId, conversationId, userId ×2 (membership).
 */
const CONVERSATION_GATE_SQL = `
  SELECT
    c.user_a_id,
    c.user_b_id,
    c.request_status,
    c.initiated_by_id,
    EXISTS (
      SELECT 1 FROM user_blocks ub
      WHERE (ub.blocker_id = ? AND ub.blocked_id =
              CASE WHEN c.user_a_id = ? THEN c.user_b_id ELSE c.user_a_id END)
         OR (ub.blocker_id =
              CASE WHEN c.user_a_id = ? THEN c.user_b_id ELSE c.user_a_id END
             AND ub.blocked_id = ?)
    ) AS is_blocked,
    EXISTS (SELECT 1 FROM messages m WHERE m.id = ?) AS message_exists,
    EXISTS (
      SELECT 1 FROM messages m
      WHERE m.id = ? AND m.sender_id = ? AND m.conversation_id = ?
    ) AS message_owned
  FROM conversations c
  WHERE c.id = ? AND (c.user_a_id = ? OR c.user_b_id = ?)`;

export class ChatRoom {
  private state: DurableObjectState;
  private env: Env;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
    state.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair(PING_FRAME, PONG_FRAME),
    );
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

    // Cap concurrent sessions per user to prevent connection leaks. Counting
    // attached sockets (not in-memory bookkeeping) keeps the cap effective
    // across hibernation.
    const existing = this.state.getWebSockets(userId);
    if (existing.length >= MAX_SESSIONS_PER_USER) {
      this.closeOldest(existing);
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair) as [WebSocket, WebSocket];

    const now = Date.now();
    const session: SessionState = {
      sessionId: crypto.randomUUID(),
      userId,
      deviceId,
      connectedAt: now,
      typingCount: 0,
      typingWindowStart: now,
    };

    this.state.acceptWebSocket(server, [userId]);
    server.serializeAttachment(session);
    server.send(JSON.stringify({ type: 'connected', userId }));

    return new Response(null, { status: 101, webSocket: client });
  }

  /** Hibernation-safe: identity and routing come from the socket attachment. */
  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== 'string') {
      this.sendFrame(ws, JSON.stringify({ type: 'error', code: 'invalid_json' }));
      return;
    }
    if (message.length > MAX_FRAME_BYTES) {
      this.closeSocket(ws, 1009, 'Frame too large');
      return;
    }

    const session = this.sessionFrom(ws);
    if (!session) return;

    await this.handleClientMessage(session, message);
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    // Sessions live on the socket itself, so cleanup is idempotent and can
    // never tear down a newer connection for the same user.
    try {
      ws.close(code, reason);
    } catch {
      // ignore
    }
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    try {
      ws.close(1011, 'Socket error');
    } catch {
      // ignore
    }
  }

  private readMeta(ws: WebSocket): SessionState | null {
    const meta = ws.deserializeAttachment() as Partial<SessionState> | null;
    if (!meta || typeof meta.userId !== 'string' || typeof meta.sessionId !== 'string') {
      return null;
    }
    return {
      sessionId: meta.sessionId,
      userId: meta.userId,
      deviceId: typeof meta.deviceId === 'number' ? meta.deviceId : null,
      connectedAt: typeof meta.connectedAt === 'number' ? meta.connectedAt : 0,
      typingCount: typeof meta.typingCount === 'number' ? meta.typingCount : 0,
      typingWindowStart: typeof meta.typingWindowStart === 'number' ? meta.typingWindowStart : 0,
    };
  }

  private sessionFrom(ws: WebSocket): Session | null {
    const meta = this.readMeta(ws);
    if (!meta) {
      // Accepted by an earlier build (pre-hibernation) or a corrupt
      // attachment — make the client reconnect and re-authenticate.
      this.closeSocket(ws, 1008, 'Session state unavailable');
      return null;
    }
    return { ...meta, ws };
  }

  private persistSession(session: Session): void {
    try {
      session.ws.serializeAttachment({
        sessionId: session.sessionId,
        userId: session.userId,
        deviceId: session.deviceId,
        connectedAt: session.connectedAt,
        typingCount: session.typingCount,
        typingWindowStart: session.typingWindowStart,
      } satisfies SessionState);
    } catch {
      // ignore
    }
  }

  private closeOldest(sockets: WebSocket[]): void {
    let oldest: WebSocket | null = null;
    let oldestAt = Number.POSITIVE_INFINITY;
    for (const ws of sockets) {
      const at = this.readMeta(ws)?.connectedAt ?? 0;
      if (at < oldestAt) {
        oldestAt = at;
        oldest = ws;
      }
    }
    if (oldest) this.closeSocket(oldest, 1000, 'Session limit reached');
  }

  private sendFrame(ws: WebSocket, frame: string): boolean {
    if (ws.readyState > SOCKET_OPEN) return false;
    try {
      ws.send(frame);
      return true;
    } catch {
      return false;
    }
  }

  private closeSocket(ws: WebSocket, code: number, reason: string): void {
    try {
      ws.close(code, reason);
    } catch {
      // ignore
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

  /**
   * Returns the number of sessions that received the event. Each session gets
   * only the ciphertext addressed to its own device, so a socket can never
   * observe payloads intended for another device.
   */
  broadcast(event: DOEvent): number {
    const payloads = (event as {
      payloads?: Array<{ deviceId: number; payload: string | null; messageType: string }>;
    }).payloads;
    const legacyFrame = payloads ? null : JSON.stringify(event);
    const frames = new Map<string, string>();

    let count = 0;
    for (const ws of this.state.getWebSockets()) {
      const meta = this.readMeta(ws);
      if (!meta) continue;

      let frame = legacyFrame;
      if (frame === null) {
        const key = meta.deviceId === null ? 'none' : String(meta.deviceId);
        const cached = frames.get(key);
        if (cached === undefined) {
          frame = JSON.stringify({
            ...event,
            payloads: payloads!.filter((p) => p.deviceId === meta.deviceId),
          });
          frames.set(key, frame);
        } else {
          frame = cached;
        }
      }

      if (this.sendFrame(ws, frame)) count++;
    }

    return count;
  }

  private async handleClientMessage(session: Session, data: string): Promise<void> {
    let msg: { type?: string; messageId?: string; requestId?: string } | null = null;
    try {
      msg = JSON.parse(data) as { type?: string; messageId?: string; requestId?: string };
    } catch {
      this.sendFrame(session.ws, JSON.stringify({ type: 'error', code: 'invalid_json' }));
      return;
    }
    if (!msg || typeof msg.type !== 'string') {
      this.sendFrame(session.ws, JSON.stringify({
        type: 'error',
        code: 'invalid_event',
        requestId: msg?.requestId,
      }));
      return;
    }

    const requestId = typeof msg.requestId === 'string' ? msg.requestId : undefined;

    // Bound frame already enforced; validate event type.
    if (msg.type === 'delivery_ack' && typeof msg.messageId === 'string' && msg.messageId.length <= 128) {
      await this.handleDeliveryAck(session.userId, msg.messageId);
      if (requestId) {
        this.sendFrame(session.ws, JSON.stringify({ type: 'ack', requestId, ok: true }));
      }
      return;
    }

    if (msg.type === 'typing_start' || msg.type === 'typing_stop') {
      // Per-connection typing flood protection; counters persist with the
      // socket so a wake-up cannot reset the window.
      const now = Date.now();
      if (now - session.typingWindowStart > TYPING_WINDOW_MS) {
        session.typingCount = 0;
        session.typingWindowStart = now;
      }
      session.typingCount++;
      this.persistSession(session);
      if (session.typingCount > MAX_TYPING_PER_WINDOW) return;

      const typingEvent = JSON.stringify({ type: msg.type, userId: session.userId });
      for (const peer of this.state.getWebSockets()) {
        const meta = this.readMeta(peer);
        if (!meta || meta.userId === session.userId) continue;
        this.sendFrame(peer, typingEvent);
      }
      return;
    }

    if (msg.type === 'ping') {
      // Fallback for heartbeats the runtime's auto-response did not match
      // (for example a frame carrying a requestId).
      this.sendFrame(session.ws, JSON.stringify({ type: 'pong', requestId }));
      return;
    }

    if (msg.type === 'send_message') {
      await this.handleSendMessage(session, msg as Record<string, unknown>, requestId);
      return;
    }

    // Explicit error for unsupported/unknown events rather than silent drop.
    this.sendFrame(session.ws, JSON.stringify({
      type: 'error',
      requestId,
      code: 'unsupported_event',
      eventType: msg.type,
    }));
  }

  private async handleDeliveryAck(recipientId: string, messageId: string): Promise<void> {
    const now = Math.floor(Date.now() / 1000);
    try {
      // Batched so the guard read and the write share one round trip.
      const [messageResult, updateResult] = await this.env.DB.batch<{ sender_id: string }>([
        this.env.DB.prepare('SELECT sender_id FROM messages WHERE id = ?').bind(messageId),
        this.env.DB.prepare(
          `UPDATE message_deliveries
           SET delivered_at = COALESCE(delivered_at, ?)
           WHERE message_id = ?
             AND delivered_at IS NULL
             AND recipient_device_id IN (SELECT id FROM devices WHERE user_id = ?)
             AND EXISTS (
               SELECT 1 FROM messages
               WHERE id = ? AND sender_id <> ?
             )`,
        ).bind(now, messageId, recipientId, messageId, recipientId),
      ]);

      const message = messageResult.results?.[0];
      if (!message || message.sender_id === recipientId) return;
      if ((updateResult.meta?.changes ?? 0) === 0) return;

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
      const sent = this.sendFrame(session.ws, JSON.stringify({ ...payload, requestId }));
      if (sent && payload.type === 'error') {
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

    const conv = await this.env.DB.prepare(CONVERSATION_GATE_SQL)
      .bind(
        userId,
        userId,
        userId,
        userId,
        msgId,
        msgId,
        userId,
        targetConversationId,
        targetConversationId,
        userId,
        userId,
      )
      .first<ConversationGateRow>();
    if (!conv) {
      sendAck({ type: 'error', code: 'forbidden', message: 'Conversation not found' });
      return;
    }

    const expectedRecipient = conv.user_a_id === userId ? conv.user_b_id : conv.user_a_id;
    if (recipientId !== expectedRecipient) {
      sendAck({ type: 'error', code: 'invalid_recipient', message: 'Invalid recipientId' });
      return;
    }

    if (conv.is_blocked === 1) {
      sendAck({ type: 'error', code: 'blocked', message: 'Messaging is blocked for this conversation' });
      return;
    }
    if (conv.request_status === 'pending' && conv.initiated_by_id !== userId) {
      sendAck({ type: 'error', code: 'request_pending', message: 'Accept the conversation before sending' });
      return;
    }
    // Only reachable for the request initiator: one unanswered request message.
    if (conv.request_status === 'pending') {
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

    // Idempotent retry: already committed by this sender in this conversation.
    if (conv.message_exists === 1) {
      if (conv.message_owned !== 1) {
        sendAck({ type: 'error', code: 'conflict', message: 'Message id conflict' });
        return;
      }
      sendAck({ type: 'ack', ok: true, messageId: msgId, status: 'already_committed' });
      return;
    }

    // Sender's own active devices (sender-device sync: each of the sender's
    // sibling installations gets a ciphertext it can decrypt) and the
    // recipient's active devices, in one round trip.
    const { own: senderDevices, peer: recipientDevices } =
      await pairedActiveDeviceIds(this.env.DB, userId, expectedRecipient);

    if (!senderDevices.includes(deviceId)) {
      sendAck({ type: 'error', code: 'device_required', message: 'Device registration required' });
      return;
    }
    if (recipientDevices.length === 0) {
      sendAck({ type: 'error', code: 'no_recipient_device', message: "Recipient hasn't registered encryption keys yet." });
      return;
    }

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

    const deliveryRows = payloads.map((p) => {
      const dp = p as Record<string, unknown>;
      return {
        deviceId: dp.deviceId as number,
        payload: dp.ciphertext as string,
        messageType: typeof dp.messageType === 'string' ? dp.messageType : messageType,
      };
    });

    // Message row, conversation timestamp and per-device ciphertexts commit
    // together: a failure rolls all three back instead of leaving a message
    // that a retry would see as already committed.
    await this.env.DB.batch([
      this.env.DB.prepare(
        `INSERT INTO messages
          (id, conversation_id, sender_id, sender_device_id, message_type, reply_to_id,
           media_id, version, is_unsent, created_at, expires_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?)`,
      ).bind(msgId, targetConversationId, userId, deviceId, messageType, replyToId, mediaId, now, null),
      this.env.DB.prepare(
        'UPDATE conversations SET last_message_at = ? WHERE id = ?',
      ).bind(now, targetConversationId),
      ...deliveryRows.map((row) =>
        this.env.DB.prepare(
          `INSERT OR IGNORE INTO message_deliveries
             (id, message_id, recipient_device_id, sender_device_id, payload,
              message_type, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)`,
        ).bind(crypto.randomUUID(), msgId, row.deviceId, deviceId, row.payload, row.messageType, now),
      ),
    ]);

    const event: DOEvent = {
      type: 'new_message',
      messageId: msgId,
      conversationId: targetConversationId,
      senderId: userId,
      senderDeviceId: deviceId,
      recipients: [userId, expectedRecipient],
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
      await notifyInboxes(this.env, [userId, expectedRecipient], (targetUserId) => [{
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
    const frame = JSON.stringify(event);
    for (const ws of this.state.getWebSockets(userId)) {
      this.sendFrame(ws, frame);
    }
  }
}
