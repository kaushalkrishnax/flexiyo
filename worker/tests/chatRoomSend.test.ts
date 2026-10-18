import { runInDurableObject } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  countRows,
  db,
  resetDatabase,
  roomStub,
  seedBlock,
  seedConversation,
  seedDevice,
  seedMessage,
  seedUser,
} from './support.js';

const CONVERSATION = 'conv-send';
const OTHER_CONVERSATION = 'conv-send-other';
const ALICE = 'user-alice';
const BOB = 'user-bob';
const CAROL = 'user-carol';

let aliceDevice = 0;
let bobDevice = 0;
let carolDevice = 0;

beforeEach(async () => {
  await resetDatabase();
  await seedUser(ALICE);
  await seedUser(BOB);
  await seedUser(CAROL);
  aliceDevice = await seedDevice(ALICE, 'install-alice');
  bobDevice = await seedDevice(BOB, 'install-bob');
  carolDevice = await seedDevice(CAROL, 'install-carol');
  await seedConversation(CONVERSATION, ALICE, BOB);
});

interface SendOutcome {
  ack: Record<string, unknown> | null;
  closed: { code: number; reason: string } | null;
}

/**
 * Drives the socket send path on the real Durable Object with a synthetic
 * socket, so acks and close frames can be asserted without a network round
 * trip. Identity lives in the attachment exactly as a live socket provides it.
 */
async function send(
  frame: Record<string, unknown>,
  options: { userId?: string; deviceId?: number | null } = {},
): Promise<SendOutcome> {
  const userId = options.userId ?? ALICE;
  const deviceId = options.deviceId === undefined ? aliceDevice : options.deviceId;

  return runInDurableObject(roomStub(CONVERSATION), async (instance) => {
    const frames: string[] = [];
    let closed: { code: number; reason: string } | null = null;
    const ws = {
      readyState: 1,
      serializeAttachment: () => {},
      deserializeAttachment: () => ({
        sessionId: 'test-session',
        userId,
        deviceId,
        connectedAt: 0,
        typingCount: 0,
        typingWindowStart: 0,
      }),
      send: (data: string) => {
        frames.push(data);
      },
      close: (code: number, reason: string) => {
        closed = { code, reason };
      },
    } as unknown as WebSocket;

    await instance.webSocketMessage(ws, JSON.stringify(frame));
    return {
      ack: frames.length > 0 ? (JSON.parse(frames[frames.length - 1]) as Record<string, unknown>) : null,
      closed,
    };
  });
}

/** Bypasses the frame-size gate to exercise validation that a socket cannot reach. */
async function sendDirect(
  frame: Record<string, unknown>,
  options: { userId?: string; deviceId?: number | null } = {},
): Promise<SendOutcome> {
  const userId = options.userId ?? ALICE;
  const deviceId = options.deviceId === undefined ? aliceDevice : options.deviceId;

  return runInDurableObject(roomStub(CONVERSATION), async (instance) => {
    const frames: string[] = [];
    const ws = {
      send: (data: string) => {
        frames.push(data);
      },
    } as unknown as WebSocket;

    await instance.handleSendMessage(
      {
        sessionId: 'test-session',
        userId,
        deviceId,
        connectedAt: 0,
        typingCount: 0,
        typingWindowStart: 0,
        ws,
      } as never,
      frame,
      typeof frame.requestId === 'string' ? frame.requestId : undefined,
    );
    return {
      ack: frames.length > 0 ? (JSON.parse(frames[frames.length - 1]) as Record<string, unknown>) : null,
      closed: null,
    };
  });
}

function message(
  overrides: Record<string, unknown> = {},
  id = '11111111-1111-4111-8111-111111111111',
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

describe('send_message', () => {
  it('commits the message, per-device ciphertexts and the conversation timestamp', async () => {
    const { ack, closed } = await send(message());

    expect(closed).toBeNull();
    expect(ack).toEqual({
      type: 'ack',
      requestId: 'req-1',
      ok: true,
      messageId: '11111111-1111-4111-8111-111111111111',
      status: 'sent',
    });

    const stored = await db
      .prepare(
        `SELECT conversation_id, sender_id, sender_device_id, message_type, reply_to_id, media_id,
                version, is_unsent, created_at, expires_at
         FROM messages WHERE id = ?`,
      )
      .bind('11111111-1111-4111-8111-111111111111')
      .first<Record<string, unknown>>();
    expect(stored).toMatchObject({
      conversation_id: CONVERSATION,
      sender_id: ALICE,
      sender_device_id: aliceDevice,
      message_type: 'signal',
      version: 1,
      is_unsent: 0,
    });
    expect(Number(stored?.created_at)).toBeGreaterThan(0);

    const deliveries = await db
      .prepare(
        `SELECT recipient_device_id, sender_device_id, payload, message_type
         FROM message_deliveries WHERE message_id = ? ORDER BY recipient_device_id`,
      )
      .bind('11111111-1111-4111-8111-111111111111')
      .all<Record<string, unknown>>();
    expect(deliveries.results).toEqual(
      expect.arrayContaining([
        {
          recipient_device_id: bobDevice,
          sender_device_id: aliceDevice,
          payload: 'ct-bob',
          message_type: 'signal',
        },
        {
          recipient_device_id: aliceDevice,
          sender_device_id: aliceDevice,
          payload: 'ct-alice',
          message_type: 'signal',
        },
      ]),
    );

    const conversation = await db
      .prepare('SELECT last_message_at FROM conversations WHERE id = ?')
      .bind(CONVERSATION)
      .first<{ last_message_at: number | null }>();
    expect(conversation?.last_message_at).toBeGreaterThan(0);
  });

  it('fans out one ciphertext per active device on both sides', async () => {
    const secondAlice = await seedDevice(ALICE, 'install-alice-2');
    const secondBob = await seedDevice(BOB, 'install-bob-2');

    const { ack } = await send(
      message({
        payloads: [
          { deviceId: bobDevice, ciphertext: 'ct-bob-1', messageType: 'signal' },
          { deviceId: secondBob, ciphertext: 'ct-bob-2', messageType: 'signal' },
          { deviceId: aliceDevice, ciphertext: 'ct-alice-1', messageType: 'signal' },
          { deviceId: secondAlice, ciphertext: 'ct-alice-2', messageType: 'signal' },
        ],
      }),
    );

    expect(ack).toMatchObject({ status: 'sent' });
    expect(await countRows('SELECT COUNT(*) AS n FROM message_deliveries')).toBe(4);
    const rows = await db
      .prepare('SELECT recipient_device_id, payload FROM message_deliveries ORDER BY recipient_device_id')
      .all<{ recipient_device_id: number; payload: string }>();
    expect(rows.results).toEqual([
      { recipient_device_id: aliceDevice, payload: 'ct-alice-1' },
      { recipient_device_id: bobDevice, payload: 'ct-bob-1' },
      { recipient_device_id: secondAlice, payload: 'ct-alice-2' },
      { recipient_device_id: secondBob, payload: 'ct-bob-2' },
    ]);
  });

  it('stores the prekey message type', async () => {
    const { ack } = await send(message({ messageType: 'prekey' }));
    expect(ack).toMatchObject({ status: 'sent' });
    const stored = await db
      .prepare('SELECT message_type FROM messages WHERE id = ?')
      .bind('11111111-1111-4111-8111-111111111111')
      .first<{ message_type: string }>();
    expect(stored?.message_type).toBe('prekey');
  });

  it('rejects a conversation the sender is not a party to', async () => {
    await seedConversation(OTHER_CONVERSATION, BOB, CAROL);
    const { ack } = await send(
      message({ conversationId: OTHER_CONVERSATION, payloads: [{ deviceId: carolDevice, ciphertext: 'ct' }] }),
    );
    expect(ack).toMatchObject({ type: 'error', code: 'forbidden' });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
  });

  it('rejects a recipient that is not the conversation peer', async () => {
    const { ack } = await send(message({ recipientId: CAROL }));
    expect(ack).toMatchObject({ type: 'error', code: 'invalid_recipient' });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
  });

  it('rejects sends while the peer has blocked the sender', async () => {
    await seedBlock(BOB, ALICE);
    const { ack } = await send(message());
    expect(ack).toMatchObject({ type: 'error', code: 'blocked' });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
  });

  it('rejects sends while the sender has blocked the peer', async () => {
    await seedBlock(ALICE, BOB);
    const { ack } = await send(message());
    expect(ack).toMatchObject({ type: 'error', code: 'blocked' });
  });

  it('rejects the recipient before the request has been accepted', async () => {
    await db
      .prepare('UPDATE conversations SET request_status = ?, initiated_by_id = ? WHERE id = ?')
      .bind('pending', ALICE, CONVERSATION)
      .run();

    const { ack } = await send(message({ recipientId: ALICE }), { userId: BOB, deviceId: bobDevice });
    expect(ack).toMatchObject({ type: 'error', code: 'request_pending' });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
  });

  it('allows the initiator exactly one message while the request is pending', async () => {
    await db
      .prepare('UPDATE conversations SET request_status = ?, initiated_by_id = ? WHERE id = ?')
      .bind('pending', ALICE, CONVERSATION)
      .run();

    const first = await send(message());
    expect(first.ack).toMatchObject({ status: 'sent' });

    const second = await send(message({}, '22222222-2222-4222-8222-222222222222'));
    expect(second.ack).toMatchObject({ type: 'error', code: 'request_pending' });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(1);
  });

  it('rejects a send from a session without a device', async () => {
    const { ack } = await send(message(), { deviceId: null });
    expect(ack).toMatchObject({ type: 'error', code: 'device_required' });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
  });

  it('rejects a send from a device that is no longer active', async () => {
    const disabled = await seedDevice(ALICE, 'install-alice-old', 'disabled');
    const { ack } = await send(message(), { deviceId: disabled });
    expect(ack).toMatchObject({ type: 'error', code: 'device_required' });
  });

  it('rejects a recipient with no active encryption keys', async () => {
    await seedConversation(OTHER_CONVERSATION, ALICE, CAROL);
    await db.prepare("UPDATE devices SET status = 'pending' WHERE user_id = ?").bind(CAROL).run();

    const { ack } = await send(
      message({
        conversationId: OTHER_CONVERSATION,
        recipientId: CAROL,
        payloads: [{ deviceId: aliceDevice, ciphertext: 'ct' }],
      }),
    );
    expect(ack).toMatchObject({ type: 'error', code: 'no_recipient_device' });
  });

  it('rejects sends without a conversation or message id', async () => {
    expect((await send(message({ conversationId: undefined }))).ack).toMatchObject({
      type: 'error',
      code: 'invalid_conversation',
    });
    expect((await send(message({ id: undefined }))).ack).toMatchObject({
      type: 'error',
      code: 'invalid_message_id',
    });
  });

  describe('payload validation', () => {
    it('treats a non-array payloads field as missing device payloads', async () => {
      const { ack } = await send(message({ payloads: 'nope' }));
      expect(ack).toMatchObject({ type: 'error', code: 'missing_device_payloads' });
      expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
    });

    it('rejects non-object entries', async () => {
      const { ack } = await send(message({ payloads: [null, { deviceId: bobDevice, ciphertext: 'ct' }] }));
      expect(ack).toMatchObject({ type: 'error', code: 'invalid_payload' });
    });

    it('rejects an invalid device id', async () => {
      for (const deviceId of [0, -1, 1.5, '1', null]) {
        const { ack } = await send(
          message({
            payloads: [
              { deviceId, ciphertext: 'ct' },
              { deviceId: bobDevice, ciphertext: 'ct-bob' },
            ],
          }),
        );
        expect(ack).toMatchObject({ type: 'error', code: 'invalid_device' });
      }
    });

    it('rejects an empty ciphertext', async () => {
      const { ack } = await send(
        message({
          payloads: [
            { deviceId: bobDevice, ciphertext: '' },
            { deviceId: aliceDevice, ciphertext: 'ct' },
          ],
        }),
      );
      expect(ack).toMatchObject({ type: 'error', code: 'missing_ciphertext' });
    });

    it('rejects oversized ciphertexts supplied outside the frame path', async () => {
      const { ack } = await sendDirect(
        message({
          payloads: [
            { deviceId: bobDevice, ciphertext: 'x'.repeat(64 * 1024 + 1) },
            { deviceId: aliceDevice, ciphertext: 'ct' },
          ],
        }),
      );
      expect(ack).toMatchObject({ type: 'error', code: 'oversized' });
    });

    it('closes the socket for a frame that exceeds the limit before validation', async () => {
      const { ack, closed } = await send(
        message({
          payloads: [
            { deviceId: bobDevice, ciphertext: 'x'.repeat(64 * 1024) },
            { deviceId: aliceDevice, ciphertext: 'ct' },
          ],
        }),
      );
      expect(ack).toBeNull();
      expect(closed).toMatchObject({ code: 1009 });
      expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
    });

    it('rejects duplicate device ids', async () => {
      const { ack } = await send(
        message({
          payloads: [
            { deviceId: bobDevice, ciphertext: 'ct-1' },
            { deviceId: bobDevice, ciphertext: 'ct-2' },
          ],
        }),
      );
      expect(ack).toMatchObject({ type: 'error', code: 'duplicate_device' });
    });

    it('rejects a device that is not part of the conversation', async () => {
      const { ack } = await send(
        message({
          payloads: [
            { deviceId: bobDevice, ciphertext: 'ct-bob' },
            { deviceId: carolDevice, ciphertext: 'ct-carol' },
          ],
        }),
      );
      expect(ack).toMatchObject({ type: 'error', code: 'unknown_device', deviceId: carolDevice });
    });

    it('rejects when an active recipient device has no ciphertext', async () => {
      const secondBob = await seedDevice(BOB, 'install-bob-2');
      const { ack } = await send(
        message({
          payloads: [
            { deviceId: bobDevice, ciphertext: 'ct-bob' },
            { deviceId: aliceDevice, ciphertext: 'ct-alice' },
          ],
        }),
      );
      expect(ack).toMatchObject({ type: 'error', code: 'missing_device_payloads' });
      expect(ack?.missingDeviceIds).toEqual([secondBob]);
    });
  });

  it('treats a retry with the same id as already committed without duplicating rows', async () => {
    await send(message());
    const { ack } = await send(message({ requestId: 'req-2' }));

    expect(ack).toEqual({
      type: 'ack',
      requestId: 'req-2',
      ok: true,
      messageId: '11111111-1111-4111-8111-111111111111',
      status: 'already_committed',
    });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(1);
    expect(await countRows('SELECT COUNT(*) AS n FROM message_deliveries')).toBe(2);
  });

  it('rejects an id already used by another conversation message', async () => {
    await seedMessage('taken-id', CONVERSATION, BOB, { senderDeviceId: bobDevice });
    const { ack } = await send(message({}, 'taken-id'));
    expect(ack).toMatchObject({ type: 'error', code: 'conflict' });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(1);
  });

  it('rolls back every write and reports send_failed when the insert fails', async () => {
    const { ack } = await send(message({ mediaId: 'missing-media-id' }));

    expect(ack).toMatchObject({ type: 'error', code: 'send_failed' });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
    expect(await countRows('SELECT COUNT(*) AS n FROM message_deliveries')).toBe(0);
    const conversation = await db
      .prepare('SELECT last_message_at FROM conversations WHERE id = ?')
      .bind(CONVERSATION)
      .first<{ last_message_at: number | null }>();
    expect(conversation?.last_message_at).toBeNull();
  });
});
