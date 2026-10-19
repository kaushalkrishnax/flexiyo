import { runInDurableObject, SELF } from 'cloudflare:test';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  db,
  openSocket,
  resetDatabase,
  roomStub,
  seedBlock,
  seedConversation,
  seedDevice,
  seedPushToken,
  seedUser,
  tokenFor,
} from './support.js';

const ALICE = 'a1a1a1a1-a1a1-4a1a-8a1a-a1a1a1a1a1a1';
const BOB = 'b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b2b2';
const CONVERSATION = 'c3c3c3c3-c3c3-4c3c-8c3c-c3c3c3c3c3c3';
const MSG_ID = '11111111-1111-4111-8111-111111111111';

let aliceDevice = 0;
let bobDevice = 0;

beforeEach(async () => {
  await resetDatabase();
  await seedUser(ALICE);
  await seedUser(BOB);
  aliceDevice = await seedDevice(ALICE, 'install-alice');
  bobDevice = await seedDevice(BOB, 'install-bob');
  await seedConversation(CONVERSATION, ALICE, BOB);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

/** Mocks OAuth + FCM and records each FCM token targeted. */
function stubFcm(handler?: (token: string) => Response): Array<{ token: string }> {
  const calls: Array<{ token: string }> = [];
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (url.startsWith('https://oauth2.googleapis.com/token')) {
      return new Response(
        JSON.stringify({ access_token: 'access-token', expires_in: 3600 }),
        { status: 200 },
      );
    }
    if (url.includes('fcm.googleapis.com')) {
      const body = JSON.parse(String(init?.body ?? '{}')) as {
        message?: { token?: string };
      };
      const token = body.message?.token ?? '';
      calls.push({ token });
      return handler
        ? handler(token)
        : new Response(JSON.stringify({ name: 'projects/flexiyo-app/messages/1' }), {
            status: 200,
          });
    }
    return new Response('unexpected request', { status: 500 });
  });
  vi.stubGlobal('fetch', fetchMock);
  return calls;
}

function message(
  overrides: Record<string, unknown> = {},
  id = MSG_ID,
): Record<string, unknown> {
  return {
    type: 'send_message',
    requestId: 'req-1',
    id,
    conversationId: CONVERSATION,
    recipientId: BOB,
    messageType: 'signal',
    payloads: [
      { deviceId: bobDevice, ciphertext: 'ct-bob', messageType: 'signal' },
      { deviceId: aliceDevice, ciphertext: 'ct-alice', messageType: 'signal' },
    ],
    ...overrides,
  };
}

/** Drives the real WebSocket send path (FCM secret comes from the test env). */
async function sendViaSocket(
  frame: Record<string, unknown>,
): Promise<Array<Record<string, unknown>>> {
  return runInDurableObject(roomStub(CONVERSATION), async (instance) => {
    const frames: string[] = [];
    const ws = {
      readyState: 1,
      serializeAttachment: () => {},
      deserializeAttachment: () => ({
        sessionId: 'test-session',
        userId: ALICE,
        deviceId: aliceDevice,
        connectedAt: 0,
        typingCount: 0,
        typingWindowStart: 0,
      }),
      send: (data: string) => {
        frames.push(data);
      },
      close: () => {},
    } as unknown as WebSocket;

    await instance.webSocketMessage(ws, JSON.stringify(frame));
    return frames.map((frame) => JSON.parse(frame) as Record<string, unknown>);
  });
}

describe('WebSocket message push notifications', () => {
  it('pushes to every registered device when the recipient has no active socket', async () => {
    await seedPushToken(BOB, 'bob-tok-1');
    await seedPushToken(BOB, 'bob-tok-2');
    const calls = stubFcm();

    const frames = await sendViaSocket(message());

    expect(frames.at(-1)).toMatchObject({ type: 'ack', ok: true, status: 'sent' });
    expect(calls.map((call) => call.token).sort()).toEqual(['bob-tok-1', 'bob-tok-2']);
  });

  it('does not push the recipient whose inbox event reached an active socket', async () => {
    await seedPushToken(BOB, 'bob-tok-1');
    const inbox = await openSocket(`inbox:${BOB}`, await tokenFor(BOB));
    const calls = stubFcm();

    await sendViaSocket(message());

    const event = await inbox.next((frame) => frame.type === 'inbox_message');
    expect(event).toMatchObject({
      type: 'inbox_message',
      conversationId: CONVERSATION,
      senderId: ALICE,
      isIncoming: true,
    });
    expect(calls).toHaveLength(0);
  });

  it('never notifies the sender about their own message', async () => {
    await seedPushToken(ALICE, 'alice-tok');
    await seedPushToken(BOB, 'bob-tok');
    const calls = stubFcm();

    await sendViaSocket(message());

    expect(calls.map((call) => call.token)).toEqual(['bob-tok']);
  });

  it('does not notify restricted (blocked) conversations', async () => {
    await seedBlock(BOB, ALICE);
    await seedPushToken(BOB, 'bob-tok');
    const calls = stubFcm();

    const frames = await sendViaSocket(message());

    expect(frames.at(-1)).toMatchObject({ type: 'error', code: 'blocked' });
    expect(calls).toHaveLength(0);
  });

  it('does not push again when an idempotent retry is already committed', async () => {
    await seedPushToken(BOB, 'bob-tok');
    const calls = stubFcm();

    await sendViaSocket(message());
    const retry = await sendViaSocket(message({ requestId: 'req-2' }));

    expect(retry.at(-1)).toMatchObject({ status: 'already_committed' });
    expect(calls).toHaveLength(1);
  });

  it('keeps the message send successful when FCM is unavailable', async () => {
    await seedPushToken(BOB, 'bob-tok');
    stubFcm(
      () =>
        new Response(JSON.stringify({ error: { status: 'INTERNAL' } }), { status: 500 }),
    );

    const frames = await sendViaSocket(message());

    expect(frames.at(-1)).toMatchObject({ type: 'ack', ok: true, status: 'sent' });
    const retained = await db
      .prepare('SELECT COUNT(*) AS n FROM push_tokens WHERE token = ?')
      .bind('bob-tok')
      .first<{ n: number }>();
    expect(retained?.n).toBe(1);
  });

  it('follows the same notification policy over HTTP as over WebSocket', async () => {
    await seedPushToken(BOB, 'bob-tok-1');
    await seedPushToken(BOB, 'bob-tok-2');
    const calls = stubFcm();

    const response = await SELF.fetch(
      new Request(`https://example.com/api/conversations/${CONVERSATION}/messages`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${await tokenFor(ALICE)}`,
          'X-Installation-Id': 'install-alice',
        },
        body: JSON.stringify({
          id: crypto.randomUUID(),
          payloads: [{ deviceId: bobDevice, ciphertext: 'ct-bob', messageType: 'signal' }],
          messageType: 'signal',
          recipientId: BOB,
        }),
      }),
    );

    expect(response.status).toBe(201);
    expect(calls.map((call) => call.token).sort()).toEqual(['bob-tok-1', 'bob-tok-2']);
  });
});
