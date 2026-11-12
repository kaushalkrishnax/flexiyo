import { runInDurableObject } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  countRows,
  db,
  resetDatabase,
  roomStub,
  seedConversation,
  seedConversationKeyDevice,
  seedConversationKeyEpoch,
  seedUser,
} from './support.js';

const CONVERSATION = 'conv-v2-send';
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
  aliceDevice = await seedConversationKeyDevice(ALICE, 'v2-alice');
  bobDevice = await seedConversationKeyDevice(BOB, 'v2-bob');
  await seedConversation(CONVERSATION, ALICE, BOB);
  await seedConversationKeyEpoch(
    CONVERSATION,
    1,
    aliceDevice,
    [aliceDevice, bobDevice],
  );
});

interface SendOutcome {
  ack: Record<string, unknown> | null;
}

async function send(
  frame: Record<string, unknown>,
  options: { userId?: string; deviceId?: number | null } = {},
): Promise<SendOutcome> {
  const userId = options.userId ?? ALICE;
  const deviceId = options.deviceId === undefined ? aliceDevice : options.deviceId;

  return runInDurableObject(roomStub(CONVERSATION), async (instance) => {
    const frames: string[] = [];
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
      close: () => {},
    } as unknown as WebSocket;

    await instance.webSocketMessage(ws, JSON.stringify(frame));
    return {
      ack: frames.length > 0
        ? (JSON.parse(frames[frames.length - 1]) as Record<string, unknown>)
        : null,
    };
  });
}

function v2Frame(
  overrides: Record<string, unknown> = {},
  id = '11111111-1111-4111-8111-111111111111',
): Record<string, unknown> {
  return {
    type: 'send_message',
    requestId: 'req-v2',
    id,
    conversationId: CONVERSATION,
    recipientId: BOB,
    messageType: 'signal',
    encryptionVersion: 2,
    ciphertext: CIPHERTEXT,
    nonce: NONCE,
    authTag: TAG,
    keyEpoch: 1,
    ...overrides,
  };
}

describe('ChatRoom v2 conversation-key sends', () => {
  it('persists one ciphertext and no per-device delivery rows', async () => {
    const outcome = await send(v2Frame());

    expect(outcome.ack).toMatchObject({
      type: 'ack',
      ok: true,
      status: 'sent',
    });

    const message = await db
      .prepare(
        `SELECT ciphertext, nonce, auth_tag, key_epoch, encryption_version,
                sender_device_id, delivered_at, read_at
         FROM messages WHERE conversation_id = ?`,
      )
      .bind(CONVERSATION)
      .first<{
        ciphertext: string;
        nonce: string;
        auth_tag: string;
        key_epoch: number;
        encryption_version: number;
        sender_device_id: number;
      }>();
    expect(message).toMatchObject({
      ciphertext: CIPHERTEXT,
      nonce: NONCE,
      auth_tag: TAG,
      key_epoch: 1,
      encryption_version: 2,
      sender_device_id: aliceDevice,
    });
    expect(await countRows('SELECT COUNT(*) AS n FROM message_deliveries')).toBe(0);
    expect(
      await countRows(
        'SELECT COUNT(*) AS n FROM messages WHERE conversation_id = ? AND delivered_at IS NULL',
        CONVERSATION,
      ),
    ).toBe(1);
  });

  it('treats a retry of the same id as already committed', async () => {
    const first = await send(v2Frame());
    expect(first.ack).toMatchObject({ ok: true, status: 'sent' });

    const retry = await send(v2Frame({ requestId: 'req-v2-retry' }));
    expect(retry.ack).toMatchObject({
      type: 'ack',
      ok: true,
      status: 'already_committed',
    });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(1);
  });

  it('rejects a send while key rotation is required', async () => {
    await db
      .prepare('UPDATE conversations SET key_rotation_required = 1 WHERE id = ?')
      .bind(CONVERSATION)
      .run();

    const outcome = await send(v2Frame());

    expect(outcome.ack).toMatchObject({
      type: 'error',
      code: 'key_rotation_required',
    });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
  });

  it('rejects a stale encryption epoch', async () => {
    const outcome = await send(v2Frame({ keyEpoch: 2 }));

    expect(outcome.ack).toMatchObject({
      type: 'error',
      code: 'key_epoch_conflict',
      currentEpoch: 1,
    });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
  });

  it('rejects a send when a device has no key envelope', async () => {
    await db
      .prepare(
        'DELETE FROM device_key_envelopes WHERE conversation_id = ? AND recipient_device_id = ?',
      )
      .bind(CONVERSATION, bobDevice)
      .run();

    const outcome = await send(v2Frame());

    expect(outcome.ack).toMatchObject({
      type: 'error',
      code: 'conversation_keys_not_provisioned',
    });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
  });

  it('rejects a v1 device trying to send a v2 message', async () => {
    await db
      .prepare('UPDATE devices SET encryption_version = 1 WHERE id = ?')
      .bind(aliceDevice)
      .run();

    const outcome = await send(v2Frame());

    expect(outcome.ack).toMatchObject({
      type: 'error',
      code: 'device_required',
    });
  });
});
