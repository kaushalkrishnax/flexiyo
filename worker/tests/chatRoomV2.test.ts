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
  it('persists one ciphertext and updates conversation_user_state', async () => {
    const outcome = await send(v2Frame());

    expect(outcome.ack).toMatchObject({
      type: 'ack',
      ok: true,
      status: 'sent',
    });

    const message = await db
      .prepare(
        `SELECT ciphertext, nonce, auth_tag, key_epoch,
                sender_device_id, delivered_at, read_at
         FROM messages WHERE conversation_id = ?`,
      )
      .bind(CONVERSATION)
      .first<{
        ciphertext: string;
        nonce: string;
        auth_tag: string;
        key_epoch: number;
        sender_device_id: number;
      }>();
    expect(message).toMatchObject({
      ciphertext: CIPHERTEXT,
      nonce: NONCE,
      auth_tag: TAG,
      key_epoch: 1,
      sender_device_id: aliceDevice,
    });
    expect(
      await countRows(
        'SELECT COUNT(*) AS n FROM messages WHERE conversation_id = ? AND delivered_at IS NULL',
        CONVERSATION,
      ),
    ).toBe(1);

    const bobState = await db
      .prepare('SELECT unread_count FROM conversation_user_state WHERE conversation_id = ? AND user_id = ?')
      .bind(CONVERSATION, BOB)
      .first<{ unread_count: number }>();
    expect(bobState?.unread_count).toBe(1);

    const conv = await db
      .prepare('SELECT last_message_sender_id FROM conversations WHERE id = ?')
      .bind(CONVERSATION)
      .first<{ last_message_sender_id: string | null }>();
    expect(conv?.last_message_sender_id).toBe(ALICE);
  });

  it('rejects a legacy v1 payloads frame', async () => {
    const outcome = await send({
      type: 'send_message',
      requestId: 'req-v1',
      id: '11111111-1111-4111-8111-111111111111',
      conversationId: CONVERSATION,
      recipientId: BOB,
      payloads: [{ deviceId: bobDevice, ciphertext: 'ct' }],
    });

    expect(outcome.ack).toMatchObject({
      type: 'error',
      code: 'invalid_v2_payload',
    });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
  });

  it('treats a retry of the same id as already committed without double-counting unread', async () => {
    const first = await send(v2Frame());
    expect(first.ack).toMatchObject({ ok: true, status: 'sent' });

    const retry = await send(v2Frame({ requestId: 'req-v2-retry' }));
    expect(retry.ack).toMatchObject({
      type: 'ack',
      ok: true,
      status: 'already_committed',
    });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(1);
    const bobState = await db
      .prepare('SELECT unread_count FROM conversation_user_state WHERE conversation_id = ? AND user_id = ?')
      .bind(CONVERSATION, BOB)
      .first<{ unread_count: number }>();
    expect(bobState?.unread_count).toBe(1);
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

  it('rejects a device without an identity public key trying to send', async () => {
    await db
      .prepare('UPDATE devices SET identity_public_key = NULL WHERE id = ?')
      .bind(aliceDevice)
      .run();

    const outcome = await send(v2Frame());

    expect(outcome.ack).toMatchObject({
      type: 'error',
      code: 'device_required',
    });
  });
});
