import { env, runInDurableObject } from 'cloudflare:test';
import { afterEach, expect } from 'vitest';
import { signJWT } from '../src/utils/jwt.js';
import type { Env } from '../src/types.js';

export const testEnv = env as unknown as Env;
export const db: D1Database = testEnv.DB;

const trackedSockets = new Set<TestSocket>();
const trackedRooms = new Set<string>();

// Storage isolation is disabled for this project (WebSockets and per-file
// isolation are incompatible), so each test starts from a known empty schema.
export async function resetDatabase(): Promise<void> {
  const tables = [
    'media_views',
    'message_reactions',
    'message_deliveries',
    'local_deletions',
    'messages',
    'media',
    'conversations',
    'pre_keys',
    'push_tokens',
    'daily_usage',
    'email_verification_codes',
    'token_revocations',
    'user_blocks',
    'rate_limit_buckets',
    'devices',
    'users',
    'worker_meta',
  ];
  await db.batch(tables.map((table) => db.prepare(`DELETE FROM ${table}`)));
}

export async function seedUser(id: string): Promise<void> {
  await db
    .prepare(`INSERT INTO users (id, username, password_hash, created_at) VALUES (?, ?, 'x', 0)`)
    .bind(id, `user-${id}`)
    .run();
}

export async function seedDevice(
  userId: string,
  installationId: string,
  status: 'active' | 'pending' | 'disabled' | 'logged_out' = 'active',
): Promise<number> {
  const result = await db
    .prepare(
      `INSERT INTO devices
         (user_id, installation_id, registration_id, identity_key,
          signed_pre_key_id, signed_pre_key_public, signed_pre_key_signature,
          status, created_at)
       VALUES (?, ?, 1, 'identity-key', 1, 'signed-pre-key', 'signature', ?, 0)`,
    )
    .bind(userId, installationId, status)
    .run();
  return Number(result.meta.last_row_id);
}

export async function seedConversation(
  id: string,
  userA: string,
  userB: string,
  options: { requestStatus?: 'pending' | 'accepted' | 'rejected'; initiatedById?: string | null; disappearingTimer?: number } = {},
): Promise<void> {
  const [a, b] = userA < userB ? [userA, userB] : [userB, userA];
  await db
    .prepare(
      `INSERT INTO conversations
         (id, user_a_id, user_b_id, initiated_by_id, request_status, disappearing_timer, created_at)
       VALUES (?, ?, ?, ?, ?, ?, 0)`,
    )
    .bind(
      id,
      a,
      b,
      options.initiatedById ?? null,
      options.requestStatus ?? 'accepted',
      options.disappearingTimer ?? 0,
    )
    .run();
}

export async function seedBlock(blockerId: string, blockedId: string): Promise<void> {
  await db
    .prepare(`INSERT INTO user_blocks (id, blocker_id, blocked_id, created_at) VALUES (?, ?, ?, 0)`)
    .bind(crypto.randomUUID(), blockerId, blockedId)
    .run();
}

export async function seedMessage(
  id: string,
  conversationId: string,
  senderId: string,
  options: { senderDeviceId?: number | null; isUnsent?: boolean; createdAt?: number } = {},
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO messages
         (id, conversation_id, sender_id, sender_device_id, message_type, version, is_unsent, created_at)
       VALUES (?, ?, ?, ?, 'signal', 1, ?, ?)`,
    )
    .bind(
      id,
      conversationId,
      senderId,
      options.senderDeviceId ?? null,
      options.isUnsent ? 1 : 0,
      options.createdAt ?? 0,
    )
    .run();
}

/** Access token for a user, signed with the test runtime's JWT secret. */
export function tokenFor(userId: string, jti: string = crypto.randomUUID()): Promise<string> {
  return signJWT({ sub: userId, username: `user-${userId}`, jti }, testEnv.JWT_SECRET);
}

interface Waiter {
  predicate: (frame: Record<string, unknown>) => boolean;
  resolve: (frame: Record<string, unknown>) => void;
  timer: ReturnType<typeof setTimeout>;
}

export interface TestSocket {
  ws: WebSocket;
  /** Next frame matching `predicate`, waiting up to `timeoutMs`. */
  next(
    predicate?: (frame: Record<string, unknown>) => boolean,
    timeoutMs?: number,
  ): Promise<Record<string, unknown>>;
  /** Resolves when the server closes this socket. */
  closed: Promise<{ code: number }>;
  close(): void;
}

export function trackSocket(ws: WebSocket): TestSocket {
  const queued: Array<Record<string, unknown>> = [];
  const waiters: Waiter[] = [];
  let closeInfo: { code: number } | null = null;
  let resolveClose: (value: { code: number }) => void = () => {};
  const closed = new Promise<{ code: number }>((resolve) => {
    resolveClose = resolve;
  });

  const drain = () => {
    for (let i = 0; i < waiters.length; ) {
      const waiter = waiters[i];
      const index = queued.findIndex(waiter.predicate);
      if (index === -1) {
        i++;
        continue;
      }
      const [frame] = queued.splice(index, 1);
      clearTimeout(waiter.timer);
      waiters.splice(i, 1);
      waiter.resolve(frame);
    }
  };

  ws.addEventListener('message', (event) => {
    if (typeof event.data !== 'string') return;
    queued.push(JSON.parse(event.data) as Record<string, unknown>);
    drain();
  });
  ws.addEventListener('close', (event) => {
    const closeEvent = event as CloseEvent;
    closeInfo = { code: closeEvent.code };
    try {
      // A real browser peer completes the closing handshake automatically;
      // the in-process test client has to reply explicitly.
      ws.close(closeEvent.code, closeEvent.reason);
    } catch {
      // ignore
    }
    resolveClose(closeInfo);
  });

  return {
    ws,
    closed,
    close: () => {
      try {
        ws.close(1000, 'client closed');
      } catch {
        // ignore
      }
    },
    next(predicate = () => true, timeoutMs = 5_000) {
      const index = queued.findIndex(predicate);
      if (index !== -1) return Promise.resolve(queued.splice(index, 1)[0]);
      if (closeInfo) {
        return Promise.reject(new Error(`socket closed (${closeInfo.code}); queued=${JSON.stringify(queued)}`));
      }
      return new Promise<Record<string, unknown>>((resolve, reject) => {
        const timer = setTimeout(() => {
          waiters.splice(
            waiters.findIndex((waiter) => waiter.timer === timer),
            1,
          );
          reject(new Error(`no WebSocket frame within ${timeoutMs}ms; queued=${JSON.stringify(queued)}`));
        }, timeoutMs);
        waiters.push({ predicate, resolve, timer });
      });
    },
  };
}

/** Opens a WebSocket against the DO named `name` and tracks incoming frames. */
export async function openSocket(
  name: string,
  token: string,
  deviceId?: number,
): Promise<TestSocket> {
  const stub = testEnv.CHAT_ROOM.get(testEnv.CHAT_ROOM.idFromName(name));
  const url = new URL('https://internal/ws');
  url.searchParams.set('token', token);
  if (deviceId != null) url.searchParams.set('deviceId', String(deviceId));

  const response = await stub.fetch(
    new Request(url.toString(), { headers: { Upgrade: 'websocket' } }),
  );
  if (response.status !== 101) {
    throw new Error(`socket upgrade failed: ${response.status} ${await response.text()}`);
  }
  const ws = response.webSocket;
  expect(ws).toBeTruthy();
  ws!.accept();
  const socket = trackSocket(ws!);
  trackedSockets.add(socket);
  trackedRooms.add(name);
  return socket;
}

function withTimeout(promise: Promise<unknown>, ms: number): Promise<void> {
  return Promise.race([
    promise.then(
      () => undefined,
      () => undefined,
    ),
    new Promise<void>((resolve) => setTimeout(resolve, ms)),
  ]);
}

// Isolated storage can only be popped once every Durable Object has released
// its sockets, so tear down sessions even when a test forgets to.
afterEach(async () => {
  const sockets = [...trackedSockets];
  const rooms = [...trackedRooms];
  trackedSockets.clear();
  trackedRooms.clear();

  for (const socket of sockets) socket.close();
  await Promise.all(sockets.map((socket) => withTimeout(socket.closed, 2_000)));

  // Force a round trip so any pending close events are processed before the
  // storage stack is measured.
  for (const name of rooms) {
    await runInDurableObject(roomStub(name), async (_instance, state) => {
      for (const ws of state.getWebSockets()) {
        try {
          ws.close(1000, 'test teardown');
        } catch {
          // ignore
        }
      }
    });
  }
});

export function roomStub(name: string): DurableObjectStub {
  return testEnv.CHAT_ROOM.get(testEnv.CHAT_ROOM.idFromName(name));
}

export async function countRows(sql: string, ...binds: unknown[]): Promise<number> {
  const row = await db.prepare(sql).bind(...binds).first<{ n: number }>();
  return row?.n ?? 0;
}
