import { runInDurableObject } from 'cloudflare:test';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ChatRoom } from '../src/sockets/chatRoom.js';
import {
  countRows,
  openSocket,
  resetDatabase,
  roomStub,
  seedConversation,
  seedConversationKeyDevice,
  seedConversationKeyEpoch,
  seedUser,
  testEnv,
  tokenFor,
} from './support.js';
import type { Env } from '../src/types.js';

const CONVERSATION = 'conv-sockets';
const ALICE = 'user-alice';
const BOB = 'user-bob';
const NONCE = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const TAG = 'AAAAAAAAAAAAAAAAAAAAAA==';
const CIPHERTEXT = 'YWJj';

let aliceDevice = 0;
let bobDevice = 0;

beforeEach(async () => {
  await resetDatabase();
  await seedUser(ALICE);
  await seedUser(BOB);
  aliceDevice = await seedConversationKeyDevice(ALICE, 'install-alice');
  bobDevice = await seedConversationKeyDevice(BOB, 'install-bob');
  await seedConversation(CONVERSATION, ALICE, BOB);
  await seedConversationKeyEpoch(CONVERSATION, 1, aliceDevice, [aliceDevice, bobDevice]);
});

describe('ChatRoom WebSocket lifecycle', () => {
  it('accepts an upgrade, reports the connected event and remains routable', async () => {
    const socket = await openSocket(CONVERSATION, await tokenFor(ALICE), aliceDevice);

    expect(await socket.next()).toMatchObject({ type: 'connected', userId: ALICE });

    await runInDurableObject(roomStub(CONVERSATION), async (_instance, state) => {
      const sockets = state.getWebSockets(ALICE);
      expect(sockets).toHaveLength(1);
      expect(sockets[0].deserializeAttachment()).toMatchObject({
        userId: ALICE,
        deviceId: aliceDevice,
      });
      expect(typeof sockets[0].deserializeAttachment().sessionId).toBe('string');
    });

    await runInDurableObject(roomStub(CONVERSATION), async (_instance, state) => {
      const woken = new ChatRoom(state, testEnv as unknown as Env);
      expect(woken.broadcast({
        type: 'message_deleted',
        messageId: 'msg-1',
        conversationId: CONVERSATION,
      })).toBe(1);
      expect(state.getWebSockets()).toHaveLength(1);
    });

    expect(await socket.next()).toMatchObject({ type: 'message_deleted', messageId: 'msg-1' });
  });

  it('answers the JSON heartbeat and any request-tagged ping', async () => {
    const socket = await openSocket(CONVERSATION, await tokenFor(ALICE), aliceDevice);
    await socket.next();

    await runInDurableObject(roomStub(CONVERSATION), async (_instance, state) => {
      const pair = state.getWebSocketAutoResponse();
      expect(pair?.request).toBe('{"type":"ping"}');
      expect(pair?.response).toBe('{"type":"pong"}');
    });

    socket.ws.send(JSON.stringify({ type: 'ping' }));
    expect(await socket.next()).toEqual({ type: 'pong' });

    socket.ws.send(JSON.stringify({ type: 'ping', requestId: 'req-ping' }));
    expect(await socket.next()).toEqual({ type: 'pong', requestId: 'req-ping' });
  });

  it('restores identity after hibernation instead of relying on instance memory', async () => {
    const socket = await openSocket(CONVERSATION, await tokenFor(ALICE), aliceDevice);
    await socket.next();

    await runInDurableObject(roomStub(CONVERSATION), async (_instance, state) => {
      const woken = new ChatRoom(state, testEnv as unknown as Env);
      const [server] = state.getWebSockets();
      await woken.webSocketMessage(server, JSON.stringify({ type: 'ping', requestId: 'after-wake' }));
    });

    expect(await socket.next()).toEqual({ type: 'pong', requestId: 'after-wake' });
  });

  it('closes sockets that have no hibernation metadata', async () => {
    const frames: string[] = [];
    let closeCode = 0;
    const server = {
      readyState: 1,
      serializeAttachment: () => {},
      deserializeAttachment: () => null,
      send: (frame: string) => frames.push(frame),
      close: (code: number) => {
        closeCode = code;
      },
    } as unknown as WebSocket;

    await runInDurableObject(roomStub(CONVERSATION), async () => {
      const room = new ChatRoom(
        { setWebSocketAutoResponse: () => {}, getWebSockets: () => [] } as unknown as DurableObjectState,
        testEnv as unknown as Env,
      );
      await room.webSocketMessage(server, JSON.stringify({ type: 'ping' }));
    });

    expect(closeCode).toBe(1008);
    expect(frames).toEqual([]);
  });

  it('caps concurrent sessions per user and drops the oldest', async () => {
    const token = await tokenFor(ALICE);
    const sockets = [];
    for (let i = 0; i < 9; i++) {
      sockets.push(await openSocket(CONVERSATION, token, aliceDevice));
    }
    for (const socket of sockets) await socket.next();

    expect((await sockets[0].closed).code).toBe(1000);

    await vi.waitFor(
      async () => {
        await runInDurableObject(roomStub(CONVERSATION), async (_instance, state) => {
          expect(state.getWebSockets(ALICE)).toHaveLength(8);
        });
      },
      { timeout: 5_000, interval: 100 },
    );

    await runInDurableObject(roomStub(CONVERSATION), async (_instance, state) => {
      const woken = new ChatRoom(state, testEnv as unknown as Env);
      expect(woken.broadcast({
        type: 'message_deleted',
        messageId: 'msg-cap',
        conversationId: CONVERSATION,
      })).toBe(8);
    });
    expect(await sockets[8].next()).toMatchObject({ messageId: 'msg-cap' });

    for (const socket of sockets.slice(1)) {
      expect(socket.ws.readyState).toBe(WebSocket.OPEN);
    }
    for (const socket of sockets.slice(1)) {
      socket.close();
    }
  });

  it('broadcasts v2 new_message only to sessions bound to a device', async () => {
    const aliceToken = await tokenFor(ALICE);
    const secondAliceDevice = await seedConversationKeyDevice(ALICE, 'install-alice-2');
    const bobSocket = await openSocket(CONVERSATION, await tokenFor(BOB), bobDevice);
    const alicePrimary = await openSocket(CONVERSATION, aliceToken, aliceDevice);
    const aliceSecondary = await openSocket(CONVERSATION, aliceToken, secondAliceDevice);
    const deviceLessSocket = await openSocket(CONVERSATION, aliceToken);
    await bobSocket.next();
    await alicePrimary.next();
    await aliceSecondary.next();
    await deviceLessSocket.next();

    const delivered = await runInDurableObject(roomStub(CONVERSATION), async (_instance, state) => {
      const woken = new ChatRoom(state, testEnv as unknown as Env);
      return woken.broadcast({
        type: 'new_message',
        messageId: 'msg-fanout',
        conversationId: CONVERSATION,
        senderId: ALICE,
        senderDeviceId: aliceDevice,
        recipients: [ALICE, BOB],
        encryptionVersion: 2,
        ciphertext: CIPHERTEXT,
        nonce: NONCE,
        authTag: TAG,
        keyEpoch: 1,
        messageType: 'signal',
        replyToId: null,
        createdAt: 1,
        expiresAt: null,
      });
    });

    expect(delivered).toBe(3);
    for (const socket of [bobSocket, alicePrimary, aliceSecondary]) {
      const frame = await socket.next();
      expect(frame).toMatchObject({
        type: 'new_message',
        messageId: 'msg-fanout',
        encryptionVersion: 2,
        ciphertext: CIPHERTEXT,
        nonce: NONCE,
        authTag: TAG,
        keyEpoch: 1,
      });
    }
    await expect(deviceLessSocket.next(undefined, 150)).rejects.toThrow(/no WebSocket frame/);
  });

  it('routes typing to the peer only and throttles repeats', async () => {
    const aliceToken = await tokenFor(ALICE);
    const bobSocket = await openSocket(CONVERSATION, await tokenFor(BOB), bobDevice);
    const aliceSocket = await openSocket(CONVERSATION, aliceToken, aliceDevice);
    await bobSocket.next();
    await aliceSocket.next();

    aliceSocket.ws.send(JSON.stringify({ type: 'typing_start' }));
    expect(await bobSocket.next()).toEqual({ type: 'typing_start', userId: ALICE });

    await runInDurableObject(roomStub(CONVERSATION), async (_instance, state) => {
      const [server] = state.getWebSockets(ALICE);
      expect(server.deserializeAttachment().typingCount).toBe(1);
    });

    await expect(aliceSocket.next((frame) => frame.type === 'typing_start', 250)).rejects.toThrow();

    for (let i = 0; i < 20; i++) {
      aliceSocket.ws.send(JSON.stringify({ type: 'typing_start' }));
    }
    await vi.waitFor(async () => {
      await runInDurableObject(roomStub(CONVERSATION), async (_instance, state) => {
        const [server] = state.getWebSockets(ALICE);
        expect(server.deserializeAttachment().typingCount).toBe(21);
      });
    });
    let delivered = 0;
    let drainError: unknown = null;
    for (;;) {
      try {
        await bobSocket.next((frame) => frame.type === 'typing_start', 250);
        delivered++;
      } catch (error) {
        drainError = error;
        break;
      }
    }
    expect(delivered, String(drainError)).toBe(19);
  });

  it('removes a socket from the Durable Object set when the client disconnects', async () => {
    const socket = await openSocket(CONVERSATION, await tokenFor(ALICE), aliceDevice);
    await socket.next();

    socket.close();

    await vi.waitFor(async () => {
      await runInDurableObject(roomStub(CONVERSATION), async (_instance, state) => {
        expect(state.getWebSockets()).toHaveLength(0);
      });
    });
  });
});

describe('ChatRoom frame validation', () => {
  it('reports invalid JSON and non-string frames', async () => {
    const socket = await openSocket(CONVERSATION, await tokenFor(ALICE), aliceDevice);
    await socket.next();

    socket.ws.send('not-json');
    expect(await socket.next()).toEqual({ type: 'error', code: 'invalid_json' });

    socket.ws.send(new Uint8Array([1, 2, 3]));
    expect(await socket.next()).toEqual({ type: 'error', code: 'invalid_json' });
  });

  it('reports missing and unknown event types', async () => {
    const socket = await openSocket(CONVERSATION, await tokenFor(ALICE), aliceDevice);
    await socket.next();

    socket.ws.send(JSON.stringify({ requestId: 'req-missing' }));
    expect(await socket.next()).toEqual({
      type: 'error',
      code: 'invalid_event',
      requestId: 'req-missing',
    });

    socket.ws.send(JSON.stringify({ type: 'nope', requestId: 'req-unknown' }));
    expect(await socket.next()).toEqual({
      type: 'error',
      code: 'unsupported_event',
      eventType: 'nope',
      requestId: 'req-unknown',
    });
  });

  it('closes the socket when a frame exceeds the size limit', async () => {
    const socket = await openSocket(CONVERSATION, await tokenFor(ALICE), aliceDevice);
    await socket.next();

    socket.ws.send('x'.repeat(65 * 1024));

    expect(await socket.closed).toMatchObject({ code: 1009 });
  });
});

describe('ChatRoom message delivery over sockets', () => {
  it('persists a v2 socket send, acknowledges it, and broadcasts the envelope', async () => {
    const aliceToken = await tokenFor(ALICE);
    const bobSocket = await openSocket(CONVERSATION, await tokenFor(BOB), bobDevice);
    const aliceSocket = await openSocket(CONVERSATION, aliceToken, aliceDevice);
    await bobSocket.next();
    await aliceSocket.next();

    const msgId = '11111111-1111-4111-8111-111111111111';
    aliceSocket.ws.send(JSON.stringify({
      type: 'send_message',
      requestId: 'req-send',
      id: msgId,
      conversationId: CONVERSATION,
      recipientId: BOB,
      encryptionVersion: 2,
      ciphertext: CIPHERTEXT,
      nonce: NONCE,
      authTag: TAG,
      keyEpoch: 1,
    }));

    expect(await bobSocket.next()).toMatchObject({
      type: 'new_message',
      messageId: msgId,
      encryptionVersion: 2,
      ciphertext: CIPHERTEXT,
      nonce: NONCE,
      authTag: TAG,
      keyEpoch: 1,
    });
    expect(await aliceSocket.next()).toMatchObject({
      type: 'new_message',
      messageId: msgId,
      ciphertext: CIPHERTEXT,
    });
    expect(await aliceSocket.next()).toEqual({
      type: 'ack',
      requestId: 'req-send',
      ok: true,
      messageId: msgId,
      status: 'sent',
    });

    expect(await countRows(`SELECT COUNT(*) AS n FROM messages`)).toBe(1);
    const stored = await testEnv.DB.prepare(
      'SELECT ciphertext, key_epoch FROM messages WHERE id = ?',
    ).bind(msgId).first<{ ciphertext: string; key_epoch: number }>();
    expect(stored).toEqual({ ciphertext: CIPHERTEXT, key_epoch: 1 });
  });

  it('records delivered_at on messages and broadcasts delivery acknowledgements back to the sender', async () => {
    const aliceToken = await tokenFor(ALICE);
    const bobSocket = await openSocket(CONVERSATION, await tokenFor(BOB), bobDevice);
    const aliceSocket = await openSocket(CONVERSATION, aliceToken, aliceDevice);
    await bobSocket.next();
    await aliceSocket.next();

    const msgId = '22222222-2222-4222-8222-222222222222';
    aliceSocket.ws.send(JSON.stringify({
      type: 'send_message',
      requestId: 'req-send',
      id: msgId,
      conversationId: CONVERSATION,
      recipientId: BOB,
      encryptionVersion: 2,
      ciphertext: CIPHERTEXT,
      nonce: NONCE,
      authTag: TAG,
      keyEpoch: 1,
    }));
    await bobSocket.next((frame) => frame.type === 'new_message');
    await aliceSocket.next((frame) => frame.type === 'ack');

    bobSocket.ws.send(JSON.stringify({
      type: 'delivery_ack',
      messageId: msgId,
      requestId: 'req-ack',
    }));

    const delivered = await aliceSocket.next((frame) => frame.type === 'message_delivered');
    expect(delivered).toMatchObject({
      messageId: msgId,
      recipientId: BOB,
      recipientDeviceId: bobDevice,
    });
    expect(await bobSocket.next()).toEqual({ type: 'ack', requestId: 'req-ack', ok: true });

    const row = await testEnv.DB.prepare(
      'SELECT delivered_at FROM messages WHERE id = ?',
    ).bind(msgId).first<{ delivered_at: number | null }>();
    expect(row?.delivered_at).toBeGreaterThan(0);
  });

  it('keeps sending after the conversation was re-created by a woken instance', async () => {
    const aliceToken = await tokenFor(ALICE);
    const aliceSocket = await openSocket(CONVERSATION, aliceToken, aliceDevice);
    await aliceSocket.next();

    await runInDurableObject(roomStub(CONVERSATION), async (_instance, state) => {
      const woken = new ChatRoom(state, testEnv as unknown as Env);
      const [server] = state.getWebSockets(ALICE);
      await woken.webSocketMessage(server, JSON.stringify({
        type: 'send_message',
        requestId: 'req-woken',
        id: '33333333-3333-4333-8333-333333333333',
        conversationId: CONVERSATION,
        recipientId: BOB,
        encryptionVersion: 2,
        ciphertext: CIPHERTEXT,
        nonce: NONCE,
        authTag: TAG,
        keyEpoch: 1,
      }));
    });

    await aliceSocket.next((frame) => frame.type === 'new_message');
    expect(await aliceSocket.next((frame) => frame.type === 'ack')).toMatchObject({
      requestId: 'req-woken',
      status: 'sent',
    });
  });
});

describe('ChatRoom inbox hubs', () => {
  it('broadcasts inbox events verbatim to the user inbox sockets', async () => {
    const inboxSocket = await openSocket(`inbox:${ALICE}`, await tokenFor(ALICE));
    await inboxSocket.next();

    const response = await roomStub(`inbox:${ALICE}`).fetch(
      new Request('https://internal/broadcast', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          events: [{
            type: 'inbox_message',
            conversationId: CONVERSATION,
            senderId: BOB,
            preview: 'New message',
            lastMessageAt: 123,
            isIncoming: true,
          }],
        }),
      }),
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ delivered: 1 });

    expect(await inboxSocket.next()).toEqual({
      type: 'inbox_message',
      conversationId: CONVERSATION,
      senderId: BOB,
      preview: 'New message',
      lastMessageAt: 123,
      isIncoming: true,
    });
  });

  it('rejects socket upgrades with a bad token', async () => {
    const stub = roomStub(CONVERSATION);
    for (const query of ['', '?token=not-a-jwt']) {
      const response = await stub.fetch(new Request(`https://internal/ws${query}`, {
        headers: { Upgrade: 'websocket' },
      }));
      expect(response.status).toBe(401);
    }
  });
});
