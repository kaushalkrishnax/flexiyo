import { describe, expect, it } from 'vitest';
import { ChatRoom } from '../src/sockets/chatRoom.js';
import type { Env } from '../src/types.js';

type ComputeFirst = (binds: unknown[]) => any;
type ComputeAll = (binds: unknown[]) => any[];

interface StmtStub {
  firstRow?: any;
  computeFirst?: ComputeFirst;
  computeAll?: ComputeAll;
}

class FakeStmt {
  sql: string;
  binds: unknown[] = [];
  computeFirst: ComputeFirst | null = null;
  computeAll: ComputeAll | null = null;
  firstRow: any = null;
  constructor(sql: string) {
    this.sql = sql;
  }
  bind(...vals: unknown[]) {
    this.binds = vals;
    return this;
  }
  async run() {
    return { success: true };
  }
  async first<T>() {
    if (this.computeFirst) return this.computeFirst(this.binds) as unknown as T;
    return this.firstRow as unknown as T;
  }
  async all<T>() {
    if (this.computeAll) return { results: this.computeAll(this.binds) as T[] };
    return { results: [] as T[] };
  }
}

class FakeDB {
  stmts: FakeStmt[] = [];
  private stubs = new Map<string, StmtStub>();
  stub(sql: string, cfg: StmtStub) {
    this.stubs.set(sql, cfg);
  }
  prepare(sql: string) {
    const stmt = new FakeStmt(sql);
    const cfg = this.stubs.get(sql);
    if (cfg) {
      if (cfg.firstRow !== undefined) stmt.firstRow = cfg.firstRow;
      if (cfg.computeFirst) stmt.computeFirst = cfg.computeFirst;
      if (cfg.computeAll) stmt.computeAll = cfg.computeAll;
    }
    this.stmts.push(stmt);
    return stmt;
  }
  async batch() {
    return undefined;
  }
}

function makeDevices(deviceIds: number[]) {
  return deviceIds.map((id) => ({ id }));
}

function devicesFor(binds: unknown[], devicesByUser: Record<string, number[]>) {
  return makeDevices(devicesByUser[binds[0] as string] ?? []);
}

function deviceById(
  binds: unknown[],
  devicesByUser: Record<string, number[]>,
) {
  const devId = Number(binds[0]);
  const userId = binds[1];
  return devicesByUser[userId as string]?.includes(devId)
    ? { id: devId }
    : null;
}

function fakeEnv(): { env: Env; db: FakeDB } {
  const db = new FakeDB();
  const env: Env = {
    DB: db as unknown as D1Database,
    CHAT_ROOM: {
      idFromName: (name: string) => name,
      get: () => ({
        fetch: async () =>
          new Response(JSON.stringify({ delivered: 1 }), {
            headers: { 'Content-Type': 'application/json' },
          }),
      }),
    } as unknown as DurableObjectNamespace,
    JWT_SECRET: 'test-secret',
    CORS_ORIGIN: 'http://localhost',
  };
  return { env, db };
}

async function roomHandleSendMessage(
  db: FakeDB,
  session: { userId: string; deviceId: number; sent: unknown[] },
  msg: Record<string, unknown>,
) {
  const env = {
    DB: db as unknown as D1Database,
    CHAT_ROOM: {
      idFromName: (name: string) => name,
      get: () => ({
        fetch: async () =>
          new Response(JSON.stringify({ delivered: 1 }), {
            headers: { 'Content-Type': 'application/json' },
          }),
      }),
    } as unknown as DurableObjectNamespace,
    JWT_SECRET: 'test-secret',
    CORS_ORIGIN: 'http://localhost',
  } as Env;
  const room = new ChatRoom({} as never, env);
  await room.handleSendMessage(session as any, msg, msg.requestId);
  // handleSendMessage returns void; the ack is delivered over the WS frame.
  const frame = session.sent[session.sent.length - 1];
  return frame ? JSON.parse(String(frame)) : null;
}

function capturingSession(
  userId: string,
  deviceId: number,
): { userId: string; deviceId: number; sent: unknown[] } {
  const sent: unknown[] = [];
  return {
    userId,
    deviceId,
    sent,
    ws: { send: (data: unknown) => sent.push(data) } as unknown as WebSocket,
  };
}

describe('ChatRoom handleSendMessage', () => {
  it('persists sender and all payloads, then acknowledges success', async () => {
    const devicesByUser = { 'u-bob': [3], 'u-alice': [1] };
    const { env, db } = fakeEnv();

    db.stub(
      "SELECT id, user_a_id, user_b_id FROM conversations WHERE id = ? AND (user_a_id = ? OR user_b_id = ?)",
      { firstRow: { id: 'c-1', user_a_id: 'u-alice', user_b_id: 'u-bob' } },
    );
    db.stub(
      "SELECT id FROM devices WHERE id = ? AND user_id = ? AND status = 'active'",
      { computeFirst: (b) => deviceById(b, devicesByUser) },
    );
    db.stub(
      "SELECT id FROM devices WHERE user_id = ? AND status = 'active' ORDER BY id",
      { computeAll: (b) => devicesFor(b, devicesByUser) },
    );

    const session = capturingSession('u-alice', 1);

    const ack = await roomHandleSendMessage(db, session, {
      type: 'send_message',
      requestId: 'req-1',
      id: 'msg-1',
      conversationId: 'c-1',
      recipientId: 'u-bob',
      messageType: 'signal',
      payloads: [
        { deviceId: 3, ciphertext: 'ct-bob', messageType: 'signal' },
        { deviceId: 1, ciphertext: 'ct-self', messageType: 'signal' },
      ],
    });

    expect(ack).toMatchObject({ type: 'ack', ok: true, messageId: 'msg-1' });

    const insertMsg = db.stmts.find((s) => s.sql.includes('INSERT INTO messages'));
    expect(insertMsg).toBeDefined();
    expect(insertMsg.binds[3]).toBe(1); // sender_device_id = sender's device

    const insertDels = db.stmts.filter((s) =>
      s.sql.includes('INSERT OR IGNORE INTO message_deliveries'),
    );
    expect(insertDels.length).toBe(2);
    const delDevices = insertDels.map((s) => s.binds[2]);
    expect(delDevices).toContain(3);
    expect(delDevices).toContain(1);
    expect(insertDels.every((s) => s.binds[3] === 1)).toBe(true); // sender_device_id
    expect(env.CHAT_ROOM).toBeDefined();
  });

  it('rejects when a recipient device payload is missing', async () => {
    const devicesByUser = { 'u-bob': [3], 'u-alice': [1] };
    const { db } = fakeEnv();

    db.stub(
      "SELECT id, user_a_id, user_b_id FROM conversations WHERE id = ? AND (user_a_id = ? OR user_b_id = ?)",
      { firstRow: { id: 'c-1', user_a_id: 'u-alice', user_b_id: 'u-bob' } },
    );
    db.stub(
      "SELECT id FROM devices WHERE id = ? AND user_id = ? AND status = 'active'",
      { computeFirst: (b) => deviceById(b, devicesByUser) },
    );
    db.stub(
      "SELECT id FROM devices WHERE user_id = ? AND status = 'active' ORDER BY id",
      { computeAll: (b) => devicesFor(b, devicesByUser) },
    );

    const session = capturingSession('u-alice', 1);

    const ack = await roomHandleSendMessage(db, session, {
      type: 'send_message',
      requestId: 'req-2',
      id: 'msg-2',
      conversationId: 'c-1',
      recipientId: 'u-bob',
      messageType: 'signal',
      payloads: [{ deviceId: 1, ciphertext: 'ct' }], // missing bob's device 3
    });

    expect(ack).toMatchObject({ type: 'error', code: 'missing_device_payloads' });
  });

  it('is idempotent: retry with same id returns already_committed', async () => {
    const devicesByUser = { 'u-bob': [3], 'u-alice': [1] };
    const { db } = fakeEnv();

    db.stub(
      "SELECT id, user_a_id, user_b_id FROM conversations WHERE id = ? AND (user_a_id = ? OR user_b_id = ?)",
      { firstRow: { id: 'c-1', user_a_id: 'u-alice', user_b_id: 'u-bob' } },
    );
    db.stub(
      "SELECT id FROM devices WHERE id = ? AND user_id = ? AND status = 'active'",
      { computeFirst: (b) => deviceById(b, devicesByUser) },
    );
    db.stub(
      "SELECT id FROM devices WHERE user_id = ? AND status = 'active' ORDER BY id",
      { computeAll: (b) => devicesFor(b, devicesByUser) },
    );
    db.stub(
      "SELECT id, sender_id, conversation_id FROM messages WHERE id = ?",
      {
        computeFirst: (() => {
          let calls = 0;
          return () => {
            calls++;
            return calls === 1
              ? null
              : { id: 'msg-3', sender_id: 'u-alice', conversation_id: 'c-1' };
          };
        })(),
      },
    );

    const session = capturingSession('u-alice', 1);

    const ack1 = await roomHandleSendMessage(db, session, {
      type: 'send_message',
      requestId: 'req-a',
      id: 'msg-3',
      conversationId: 'c-1',
      recipientId: 'u-bob',
      messageType: 'signal',
      payloads: [{ deviceId: 3, ciphertext: 'ct' }],
    });
    expect(ack1).toMatchObject({ status: 'sent' });

    const ack2 = await roomHandleSendMessage(db, session, {
      type: 'send_message',
      requestId: 'req-b',
      id: 'msg-3',
      conversationId: 'c-1',
      recipientId: 'u-bob',
      messageType: 'signal',
      payloads: [{ deviceId: 3, ciphertext: 'ct' }],
    });
    expect(ack2).toMatchObject({ status: 'already_committed' });
  });
});
