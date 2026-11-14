import type { Env, DOEvent, JWTPayload } from '../types.js';
import { verifyJWT } from '../utils/jwt.js';
import { notifyInboxes } from '../services/inbox.js';
import { sendMessagePush } from '../services/push.js';
import { validateConversationEnvelope } from '../services/conversationKeys.js';
import { consumeWindowBudget } from '../utils/windowBudget.js';
import { getSqlDb, type SqlDatabase } from '../database/turso.js';

interface SessionState {
  sessionId: string;
  userId: string;
  deviceId: number | null;
  connectedAt: number;
  typingCount: number;
  typingWindowStart: number;
  sendCount10s: number;
  sendWindow10s: number;
  sendCount60s: number;
  sendWindow60s: number;
  ackCount10s: number;
  ackWindow10s: number;
  ackCount60s: number;
  ackWindow60s: number;
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
  key_epoch: number;
  key_rotation_required: number;
  disappearing_timer: number;
}

const MAX_FRAME_BYTES = 64 * 1024;
const MAX_TYPING_PER_WINDOW = 20;
const TYPING_WINDOW_MS = 10_000;
const SEND_BURST_LIMIT = 30;
const SEND_BURST_WINDOW_MS = 10_000;
const SEND_SUSTAINED_LIMIT = 180;
const SEND_SUSTAINED_WINDOW_MS = 60_000;
const ACK_BURST_LIMIT = 120;
const ACK_BURST_WINDOW_MS = 10_000;
const ACK_SUSTAINED_LIMIT = 1_200;
const ACK_SUSTAINED_WINDOW_MS = 60_000;
const MAX_SESSIONS_PER_USER = 8;
const SOCKET_OPEN = 1;

const PING_FRAME = '{"type":"ping"}';
const PONG_FRAME = '{"type":"pong"}';

const CONVERSATION_GATE_SQL = `
  SELECT
    c.user_a_id,
    c.user_b_id,
    c.request_status,
    c.initiated_by_id,
    c.key_epoch,
    c.key_rotation_required,
    c.disappearing_timer,
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
  private db: SqlDatabase;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
    this.db = getSqlDb(env, this);
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

    if (url.pathname === '/disconnect-device' && request.method === 'POST') {
      return this.handleDisconnectDevice(request);
    }

    return new Response('Not found', { status: 404 });
  }

  private async handleDisconnectDevice(request: Request): Promise<Response> {
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return new Response('Invalid JSON', { status: 400 });
    }
    const data = body as { userId?: unknown; deviceId?: unknown };
    if (
      typeof data.userId !== 'string' ||
      !Number.isInteger(data.deviceId) ||
      (data.deviceId as number) <= 0
    ) {
      return new Response('Invalid device target', { status: 400 });
    }
    let closed = 0;
    for (const ws of this.state.getWebSockets(data.userId)) {
      const meta = this.readMeta(ws);
      if (meta?.deviceId !== data.deviceId) continue;
      this.closeSocket(ws, 4001, 'Device revoked');
      closed++;
    }
    return Response.json({ closed });
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
      const revoked = await this.db.prepare(
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
      const row = await this.db.prepare(
        `SELECT id FROM devices
         WHERE id = ? AND user_id = ? AND status = 'active' AND identity_public_key IS NOT NULL`,
      )
        .bind(parsedDeviceId, userId)
        .first<{ id: number }>();
      if (!row) {
        return new Response(JSON.stringify({ error: 'Unknown or inactive device' }), { status: 403 });
      }
      deviceId = row.id;
    }

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
      sendCount10s: 0,
      sendWindow10s: now,
      sendCount60s: 0,
      sendWindow60s: now,
      ackCount10s: 0,
      ackWindow10s: now,
      ackCount60s: 0,
      ackWindow60s: now,
    };

    this.state.acceptWebSocket(server, [userId]);
    server.serializeAttachment(session);
    server.send(JSON.stringify({ type: 'connected', userId }));

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== 'string') {
      this.sendFrame(ws, JSON.stringify({ type: 'error', code: 'invalid_json' }));
      return;
    }
    if (
      message.length > MAX_FRAME_BYTES ||
      new TextEncoder().encode(message).byteLength > MAX_FRAME_BYTES
    ) {
      this.closeSocket(ws, 1009, 'Frame too large');
      return;
    }

    const session = this.sessionFrom(ws);
    if (!session) return;

    await this.handleClientMessage(session, message);
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
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
      sendCount10s: typeof meta.sendCount10s === 'number' ? meta.sendCount10s : 0,
      sendWindow10s: typeof meta.sendWindow10s === 'number' ? meta.sendWindow10s : 0,
      sendCount60s: typeof meta.sendCount60s === 'number' ? meta.sendCount60s : 0,
      sendWindow60s: typeof meta.sendWindow60s === 'number' ? meta.sendWindow60s : 0,
      ackCount10s: typeof meta.ackCount10s === 'number' ? meta.ackCount10s : 0,
      ackWindow10s: typeof meta.ackWindow10s === 'number' ? meta.ackWindow10s : 0,
      ackCount60s: typeof meta.ackCount60s === 'number' ? meta.ackCount60s : 0,
      ackWindow60s: typeof meta.ackWindow60s === 'number' ? meta.ackWindow60s : 0,
    };
  }

  private sessionFrom(ws: WebSocket): Session | null {
    const meta = this.readMeta(ws);
    if (!meta) {
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
        sendCount10s: session.sendCount10s,
        sendWindow10s: session.sendWindow10s,
        sendCount60s: session.sendCount60s,
        sendWindow60s: session.sendWindow60s,
        ackCount10s: session.ackCount10s,
        ackWindow10s: session.ackWindow10s,
        ackCount60s: session.ackCount60s,
        ackWindow60s: session.ackWindow60s,
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

  broadcast(event: DOEvent): number {
    const recipients = (event as { recipients?: string[] }).recipients;
    const requiresDevice = event.type === 'new_message' || event.type === 'message_edited';
    const frame = JSON.stringify(event);

    let count = 0;
    for (const ws of this.state.getWebSockets()) {
      const meta = this.readMeta(ws);
      if (!meta) continue;
      if (recipients && !recipients.includes(meta.userId)) continue;
      if (requiresDevice && meta.deviceId === null) continue;

      if (this.sendFrame(ws, frame)) count++;
    }

    return count;
  }

  private checkSocketBudget(session: Session, kind: 'send' | 'ack'): number {
    const now = Date.now();
    if (kind === 'send') {
      const burst = consumeWindowBudget(
        { count: session.sendCount10s, windowStart: session.sendWindow10s },
        now,
        SEND_BURST_LIMIT,
        SEND_BURST_WINDOW_MS,
      );
      const sustained = consumeWindowBudget(
        { count: session.sendCount60s, windowStart: session.sendWindow60s },
        now,
        SEND_SUSTAINED_LIMIT,
        SEND_SUSTAINED_WINDOW_MS,
      );
      session.sendCount10s = burst.count;
      session.sendWindow10s = burst.windowStart;
      session.sendCount60s = sustained.count;
      session.sendWindow60s = sustained.windowStart;
      this.persistSession(session);
      return Math.max(burst.retryAfterMs, sustained.retryAfterMs);
    }

    const burst = consumeWindowBudget(
      { count: session.ackCount10s, windowStart: session.ackWindow10s },
      now,
      ACK_BURST_LIMIT,
      ACK_BURST_WINDOW_MS,
    );
    const sustained = consumeWindowBudget(
      { count: session.ackCount60s, windowStart: session.ackWindow60s },
      now,
      ACK_SUSTAINED_LIMIT,
      ACK_SUSTAINED_WINDOW_MS,
    );
    session.ackCount10s = burst.count;
    session.ackWindow10s = burst.windowStart;
    session.ackCount60s = sustained.count;
    session.ackWindow60s = sustained.windowStart;
    this.persistSession(session);
    return Math.max(burst.retryAfterMs, sustained.retryAfterMs);
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
      this.sendFrame(
        session.ws,
        JSON.stringify({
          type: 'error',
          code: 'invalid_event',
          requestId: msg?.requestId,
        }),
      );
      return;
    }

    const requestId = typeof msg.requestId === 'string' ? msg.requestId : undefined;

    if (
      msg.type === 'delivery_ack' &&
      typeof msg.messageId === 'string' &&
      msg.messageId.length <= 128
    ) {
      const retryAfterMs = this.checkSocketBudget(session, 'ack');
      if (retryAfterMs > 0) {
        this.sendFrame(
          session.ws,
          JSON.stringify({
            type: 'error',
            requestId,
            code: 'rate_limited',
            retryAfterMs,
          }),
        );
        return;
      }
      await this.handleDeliveryAck(session.userId, msg.messageId, session.deviceId);
      if (requestId) {
        this.sendFrame(session.ws, JSON.stringify({ type: 'ack', requestId, ok: true }));
      }
      return;
    }

    if (msg.type === 'typing_start' || msg.type === 'typing_stop') {
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
      this.sendFrame(session.ws, JSON.stringify({ type: 'pong', requestId }));
      return;
    }

    if (msg.type === 'send_message') {
      const retryAfterMs = this.checkSocketBudget(session, 'send');
      if (retryAfterMs > 0) {
        this.sendFrame(
          session.ws,
          JSON.stringify({
            type: 'error',
            requestId,
            code: 'rate_limited',
            retryAfterMs,
            message: 'Message send rate is temporarily limited. Retry the same message shortly.',
          }),
        );
        return;
      }
      await this.handleSendMessage(session, msg as Record<string, unknown>, requestId);
      return;
    }

    this.sendFrame(
      session.ws,
      JSON.stringify({
        type: 'error',
        requestId,
        code: 'unsupported_event',
        eventType: msg.type,
      }),
    );
  }

  private async handleDeliveryAck(
    recipientId: string,
    messageId: string,
    deviceId: number | null,
  ): Promise<void> {
    const now = Math.floor(Date.now() / 1000);
    try {
      const updated = await this.db.prepare(
        `UPDATE messages SET delivered_at = COALESCE(delivered_at, ?)
         WHERE id = ? AND sender_id <> ? AND delivered_at IS NULL
         RETURNING sender_id`,
      )
        .bind(now, messageId, recipientId)
        .first<{ sender_id: string }>();

      if (!updated) return;

      this.sendToUser(updated.sender_id, {
        type: 'message_delivered',
        messageId,
        recipientId,
        ...(deviceId == null ? {} : { recipientDeviceId: deviceId }),
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

    const targetConversationId =
      typeof msg.conversationId === 'string' ? msg.conversationId : null;
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
    const replyToId = typeof msg.replyToId === 'string' ? msg.replyToId : null;
    const mediaId = typeof msg.mediaId === 'string' ? msg.mediaId : null;

    const conv = await this.db.prepare(CONVERSATION_GATE_SQL)
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
      sendAck({
        type: 'error',
        code: 'blocked',
        message: 'Messaging is blocked for this conversation',
      });
      return;
    }
    if (conv.request_status === 'pending' && conv.initiated_by_id !== userId) {
      sendAck({
        type: 'error',
        code: 'request_pending',
        message: 'Accept the conversation before sending',
      });
      return;
    }
    if (conv.request_status === 'pending') {
      const prior = await this.db.prepare(
        `SELECT id FROM messages WHERE conversation_id = ? AND sender_id = ? AND is_unsent = 0 LIMIT 1`,
      )
        .bind(targetConversationId, userId)
        .first<{ id: string }>();
      if (prior) {
        sendAck({
          type: 'error',
          code: 'request_pending',
          message: 'Only one message may be sent with a pending request',
        });
        return;
      }
    }

    if (conv.message_exists === 1) {
      if (conv.message_owned !== 1) {
        sendAck({ type: 'error', code: 'conflict', message: 'Message id conflict' });
        return;
      }
      sendAck({ type: 'ack', ok: true, messageId: msgId, status: 'already_committed' });
      return;
    }

    if (msg.encryptionVersion !== 2) {
      sendAck({ type: 'error', code: 'invalid_v2_payload', message: 'encryptionVersion 2 required' });
      return;
    }

    const ciphertext = msg.ciphertext;
    const nonce = msg.nonce;
    const authTag = msg.authTag;
    const keyEpoch = msg.keyEpoch;
    if (
      !/^[0-9a-f-]{36}$/i.test(msgId) ||
      typeof ciphertext !== 'string' ||
      typeof nonce !== 'string' ||
      typeof authTag !== 'string' ||
      typeof keyEpoch !== 'number'
    ) {
      sendAck({ type: 'error', code: 'invalid_v2_payload' });
      return;
    }

    const envelope = validateConversationEnvelope({ ciphertext, nonce, authTag, keyEpoch });
    if (!envelope.ok) {
      sendAck({ type: 'error', code: envelope.error });
      return;
    }
    if (conv.key_rotation_required === 1) {
      sendAck({ type: 'error', code: 'key_rotation_required' });
      return;
    }
    if (keyEpoch !== conv.key_epoch || conv.key_epoch < 1) {
      sendAck({ type: 'error', code: 'key_epoch_conflict', currentEpoch: conv.key_epoch });
      return;
    }

    const [deviceResult, mediaResult, coverageResult] = await this.db.batch([
      this.db.prepare(
        `SELECT id FROM devices
         WHERE id = ? AND user_id = ? AND status = 'active' AND identity_public_key IS NOT NULL`,
      ).bind(deviceId, userId),
      mediaId
        ? this.db.prepare(
            `SELECT id FROM media
             WHERE id = ? AND conversation_id = ? AND sender_id = ? AND consumed = 0`,
          ).bind(mediaId, targetConversationId, userId)
        : this.db.prepare('SELECT NULL AS id WHERE 0'),
      this.db.prepare(
        `SELECT
           (SELECT COUNT(*) FROM devices
            WHERE user_id IN (?, ?) AND status = 'active' AND identity_public_key IS NOT NULL) AS active_count,
           (SELECT COUNT(*) FROM devices
            WHERE user_id = ? AND status = 'active' AND identity_public_key IS NOT NULL) AS sender_count,
           (SELECT COUNT(*) FROM devices
            WHERE user_id = ? AND status = 'active' AND identity_public_key IS NOT NULL) AS recipient_count,
           (SELECT COUNT(*) FROM device_key_envelopes e
            JOIN devices d ON d.id = e.recipient_device_id
            WHERE e.conversation_id = ? AND e.epoch = ?
              AND d.user_id IN (?, ?) AND d.status = 'active'
              AND d.identity_public_key IS NOT NULL) AS envelope_count`,
      ).bind(
        userId,
        expectedRecipient,
        userId,
        expectedRecipient,
        targetConversationId,
        keyEpoch,
        userId,
        expectedRecipient,
      ),
    ]);

    if (!deviceResult.results?.length) {
      sendAck({ type: 'error', code: 'device_required' });
      return;
    }
    if (mediaId && !mediaResult.results?.length) {
      sendAck({ type: 'error', code: 'invalid_media' });
      return;
    }
    const coverage = coverageResult.results?.[0] as
      | {
          active_count: number;
          sender_count: number;
          recipient_count: number;
          envelope_count: number;
        }
      | undefined;
    if (
      !coverage ||
      coverage.sender_count < 1 ||
      coverage.recipient_count < 1 ||
      coverage.active_count !== coverage.envelope_count
    ) {
      sendAck({ type: 'error', code: 'conversation_keys_not_provisioned' });
      return;
    }

    const now = Math.floor(Date.now() / 1000);
    const expiresAt = null;
    try {
      await this.db.batch([
        this.db.prepare(
          `INSERT INTO messages
             (id, conversation_id, sender_id, sender_device_id, message_type,
              reply_to_id, media_id, version, is_unsent, created_at, expires_at,
              ciphertext, nonce, auth_tag, key_epoch)
           VALUES (?, ?, ?, ?, 'signal', ?, ?, 1, 0, ?, ?, ?, ?, ?, ?)`,
        ).bind(
          msgId,
          targetConversationId,
          userId,
          deviceId,
          replyToId,
          mediaId,
          now,
          expiresAt,
          ciphertext,
          nonce,
          authTag,
          keyEpoch,
        ),
        this.db.prepare(
          'UPDATE conversations SET last_message_at = ?, last_message_sender_id = ? WHERE id = ?',
        ).bind(now, userId, targetConversationId),
        this.db.prepare(
          `INSERT INTO conversation_user_state (conversation_id, user_id, unread_count)
           VALUES (?, ?, 1)
           ON CONFLICT(conversation_id, user_id) DO UPDATE SET
             unread_count = conversation_user_state.unread_count + 1`,
        ).bind(targetConversationId, expectedRecipient),
        this.db.prepare(
          `INSERT OR IGNORE INTO conversation_user_state (conversation_id, user_id, unread_count)
           VALUES (?, ?, 0)`,
        ).bind(targetConversationId, userId),
        ...(mediaId
          ? [
              this.db.prepare(
                'UPDATE media SET consumed = 1 WHERE id = ? AND conversation_id = ? AND sender_id = ?',
              ).bind(mediaId, targetConversationId, userId),
            ]
          : []),
      ]);
    } catch (error) {
      console.error('Conversation-key message persistence failed', error);
      sendAck({ type: 'error', code: 'send_failed', message: 'Message could not be stored' });
      return;
    }

    const event: DOEvent = {
      type: 'new_message',
      messageId: msgId,
      conversationId: targetConversationId,
      senderId: userId,
      senderDeviceId: deviceId,
      recipients: [userId, expectedRecipient],
      encryptionVersion: 2,
      ciphertext,
      nonce,
      authTag,
      keyEpoch,
      messageType: 'signal',
      replyToId,
      createdAt: now,
      expiresAt,
    };
    this.broadcast(event);

    let activeUsers = new Set<string>();
    try {
      activeUsers = await notifyInboxes(this.env, [userId, expectedRecipient], (targetUserId) => [
        {
          type: 'inbox_message',
          conversationId: targetConversationId,
          senderId: userId,
          preview: 'New message',
          lastMessageAt: now,
          isIncoming: targetUserId !== userId,
        },
      ]);
    } catch {
      // List stays repairable through inbox resynchronization.
    }

    sendAck({ type: 'ack', ok: true, messageId: msgId, status: 'sent' });
    await sendMessagePush(this.env, {
      senderId: userId,
      recipientId: expectedRecipient,
      conversationId: targetConversationId,
      recipientHasActiveSocket: activeUsers.has(expectedRecipient),
    });
  }

  private sendToUser(userId: string, event: Record<string, unknown>): void {
    const frame = JSON.stringify(event);
    for (const ws of this.state.getWebSockets(userId)) {
      this.sendFrame(ws, frame);
    }
  }
}
