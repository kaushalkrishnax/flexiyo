import { SELF } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  db,
  resetDatabase,
  seedConversation,
  seedConversationKeyDevice,
  seedConversationKeyEpoch,
  seedUser,
  tokenFor,
} from './support.js';

const ALICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const BOB = 'bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb';
const CONVERSATION = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
const NONCE = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const TAG = 'AAAAAAAAAAAAAAAAAAAAAA==';
const CIPHERTEXT = 'YWJj';

let aliceDeviceA = 0;
let aliceDeviceB = 0;
let bobDevice = 0;

async function request(
  method: string,
  path: string,
  options: { userId?: string; installation?: string; body?: unknown } = {},
): Promise<Response> {
  const headers = new Headers({ 'Content-Type': 'application/json' });
  headers.set('Authorization', `Bearer ${await tokenFor(options.userId ?? ALICE)}`);
  if (options.installation) headers.set('X-Installation-Id', options.installation);
  return SELF.fetch(
    new Request(`https://example.com${path}`, {
      method,
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    }),
  );
}

async function sendFromBob(id = crypto.randomUUID()): Promise<Response> {
  return request('POST', `/api/conversations/${CONVERSATION}/messages`, {
    userId: BOB,
    installation: 'install-bob',
    body: {
      encryptionVersion: 2,
      id,
      recipientId: ALICE,
      ciphertext: CIPHERTEXT,
      nonce: NONCE,
      authTag: TAG,
      keyEpoch: 1,
    },
  });
}

beforeEach(async () => {
  await resetDatabase();
  await seedUser(ALICE);
  await seedUser(BOB);
  aliceDeviceA = await seedConversationKeyDevice(ALICE, 'install-alice-a');
  aliceDeviceB = await seedConversationKeyDevice(ALICE, 'install-alice-b');
  bobDevice = await seedConversationKeyDevice(BOB, 'install-bob');
  await seedConversation(CONVERSATION, ALICE, BOB);
  await seedConversationKeyEpoch(CONVERSATION, 1, bobDevice, [
    aliceDeviceA,
    aliceDeviceB,
    bobDevice,
  ]);
});

describe('incremental unread counts and peer-seen state', () => {
  it('increments unread count once per message regardless of device count and clears on read', async () => {
    const msgId = crypto.randomUUID();
    const sent = await sendFromBob(msgId);
    expect(sent.status).toBe(201);

    // Retry with same id must not double-increment unread_count.
    const retry = await sendFromBob(msgId);
    expect(retry.status).toBe(200);

    const detail = await request('GET', `/api/conversations/${CONVERSATION}`);
    expect(detail.status).toBe(200);
    expect(await detail.json()).toMatchObject({
      unreadCount: 1,
      lastMessageIsMine: false,
      peerSeenAt: null,
    });

    const bobDetailBefore = await request('GET', `/api/conversations/${CONVERSATION}`, {
      userId: BOB,
    });
    expect(await bobDetailBefore.json()).toMatchObject({
      unreadCount: 0,
      lastMessageIsMine: true,
      peerSeenAt: null,
    });

    const list = await request('GET', '/api/conversations');
    expect(list.status).toBe(200);
    const rows = (await list.json()) as Array<{
      id: string;
      unreadCount: number;
      lastMessageIsMine: boolean;
    }>;
    expect(rows.find((row) => row.id === CONVERSATION)).toMatchObject({
      unreadCount: 1,
      lastMessageIsMine: false,
    });

    const readRes = await request('POST', `/api/conversations/${CONVERSATION}/read`, {
      userId: ALICE,
      installation: 'install-alice-a',
    });
    expect(readRes.status).toBe(200);
    const { readAt } = (await readRes.json()) as { read: boolean; readAt: number };

    const detailAfter = await request('GET', `/api/conversations/${CONVERSATION}`);
    expect(await detailAfter.json()).toMatchObject({ unreadCount: 0 });

    const bobDetailAfter = await request('GET', `/api/conversations/${CONVERSATION}`, {
      userId: BOB,
    });
    expect(await bobDetailAfter.json()).toMatchObject({
      unreadCount: 0,
      peerSeenAt: readAt,
      lastMessageIsMine: true,
    });

    const state = await db
      .prepare(
        'SELECT unread_count, last_read_at FROM conversation_user_state WHERE conversation_id = ? AND user_id = ?',
      )
      .bind(CONVERSATION, ALICE)
      .first<{ unread_count: number; last_read_at: number | null }>();
    expect(state).toEqual({ unread_count: 0, last_read_at: readAt });
  });

  it('decrements unread_count and updates last_message metadata when an unread message is unsent', async () => {
    const msg1 = crypto.randomUUID();
    const msg2 = crypto.randomUUID();
    expect((await sendFromBob(msg1)).status).toBe(201);
    expect((await sendFromBob(msg2)).status).toBe(201);

    const beforeUnsend = await request('GET', `/api/conversations/${CONVERSATION}`);
    expect(await beforeUnsend.json()).toMatchObject({ unreadCount: 2 });

    const unsend = await request('DELETE', `/api/conversations/${CONVERSATION}/messages/${msg2}`, {
      userId: BOB,
      installation: 'install-bob',
    });
    expect(unsend.status).toBe(200);

    const afterUnsend = await request('GET', `/api/conversations/${CONVERSATION}`);
    expect(await afterUnsend.json()).toMatchObject({
      unreadCount: 1,
      lastMessageIsMine: false,
    });

    const unsendFirst = await request('DELETE', `/api/conversations/${CONVERSATION}/messages/${msg1}`, {
      userId: BOB,
      installation: 'install-bob',
    });
    expect(unsendFirst.status).toBe(200);

    const afterAllUnsent = await request('GET', `/api/conversations/${CONVERSATION}`);
    expect(await afterAllUnsent.json()).toMatchObject({
      unreadCount: 0,
      lastMessageAt: null,
      lastMessageIsMine: false,
    });
  });
});
