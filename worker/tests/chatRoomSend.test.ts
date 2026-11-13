import { runInDurableObject } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  countRows,
  db,
  resetDatabase,
  roomStub,
  seedBlock,
  seedConversation,
  seedConversationKeyDevice,
  seedConversationKeyEpoch,
  seedMedia,
  seedMessage,
  seedUser,
} from './support.js';

const CONVERSATION = 'conv-send';
const OTHER_CONVERSATION = 'conv-send-other';
const ALICE = 'user-alice';
const BOB = 'user-bob';
const CAROL = 'user-carol';
const NONCE = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const TAG = 'AAAAAAAAAAAAAAAAAAAAAA==';
const CIPHERTEXT = 'YWJj';

let aliceDevice = 0;
let bobDevice = 0;
let carolDevice = 0;

beforeEach(async () => {
  await resetDatabase();
  await seedUser(ALICE);
  await seedUser(BOB);
  await seedUser(CAROL);
  aliceDevice = await seedConversationKeyDevice(ALICE, 'install-alice');
  bobDevice = await seedConversationKeyDevice(BOB, 'install-bob');
  carolDevice = await seedConversationKeyDevice(CAROL, 'install-carol');
  await seedConversation(CONVERSATION, ALICE, BOB);
  await seedConversationKeyEpoch(CONVERSATION, 1, aliceDevice, [aliceDevice, bobDevice]);
});

interface SendOutcome {
  ack: Record<string, unknown> | null;
  closed: { code: number; reason: string } | null;
}

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
    encryptionVersion: 2,
    ciphertext: CIPHERTEXT,
    nonce: NONCE,
    authTag: TAG,
    keyEpoch: 1,
    ...overrides,
  };
}

describe('send_message', () => {
  it('commits the v2 message and updates conversation metadata and unread state', async () => {
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
                version, is_unsent, created_at, expires_at, ciphertext, nonce, auth_tag, key_epoch
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
      ciphertext: CIPHERTEXT,
      nonce: NONCE,
      auth_tag: TAG,
      key_epoch: 1,
    });
    expect(Number(stored?.created_at)).toBeGreaterThan(0);

    const conversation = await db
      .prepare('SELECT last_message_at, last_message_sender_id FROM conversations WHERE id = ?')
      .bind(CONVERSATION)
      .first<{ last_message_at: number | null; last_message_sender_id: string | null }>();
    expect(conversation?.last_message_at).toBeGreaterThan(0);
    expect(conversation?.last_message_sender_id).toBe(ALICE);

    const bobState = await db
      .prepare('SELECT unread_count FROM conversation_user_state WHERE conversation_id = ? AND user_id = ?')
      .bind(CONVERSATION, BOB)
      .first<{ unread_count: number }>();
    expect(bobState?.unread_count).toBe(1);
  });

  it('rejects a conversation the sender is not a party to', async () => {
    await seedConversation(OTHER_CONVERSATION, BOB, CAROL);
    await seedConversationKeyEpoch(OTHER_CONVERSATION, 1, bobDevice, [bobDevice, carolDevice]);
    const { ack } = await send(
      message({ conversationId: OTHER_CONVERSATION, recipientId: CAROL }),
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
    const disabled = await seedConversationKeyDevice(ALICE, 'install-alice-old', undefined, 'disabled');
    const { ack } = await send(message(), { deviceId: disabled });
    expect(ack).toMatchObject({ type: 'error', code: 'device_required' });
  });

  it('rejects a recipient with no active devices', async () => {
    await seedConversation(OTHER_CONVERSATION, ALICE, CAROL);
    await seedConversationKeyEpoch(OTHER_CONVERSATION, 1, aliceDevice, [aliceDevice, carolDevice]);
    await db.prepare("UPDATE devices SET status = 'pending' WHERE user_id = ?").bind(CAROL).run();

    const { ack } = await send(
      message({
        conversationId: OTHER_CONVERSATION,
        recipientId: CAROL,
      }),
    );
    expect(ack).toMatchObject({ type: 'error', code: 'conversation_keys_not_provisioned' });
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

  describe('envelope validation', () => {
    it('rejects an invalid envelope ciphertext or missing fields', async () => {
      const { ack: noV2 } = await send(message({ encryptionVersion: 1 }));
      expect(noV2).toMatchObject({ type: 'error', code: 'invalid_v2_payload' });

      const { ack: empty } = await send(message({ ciphertext: '' }));
      expect(empty).toMatchObject({ type: 'error', code: 'missing_ciphertext' });

      const { ack: badCiphertext } = await send(message({ ciphertext: 'not-base64!' }));
      expect(badCiphertext).toMatchObject({ type: 'error', code: 'invalid_ciphertext' });

      const { ack: badNonce } = await send(message({ nonce: 'not-base64' }));
      expect(badNonce).toMatchObject({ type: 'error', code: 'invalid_nonce' });
    });

    it('rejects oversized ciphertexts supplied outside the frame path', async () => {
      const { ack } = await sendDirect(
        message({ ciphertext: 'A'.repeat(88 * 1024) }),
      );
      expect(ack).toMatchObject({ type: 'error', code: 'invalid_ciphertext' });
    });

    it('closes the socket for a frame that exceeds the limit before validation', async () => {
      const { ack, closed } = await send(
        message({ ciphertext: 'A'.repeat(64 * 1024) }),
      );
      expect(ack).toBeNull();
      expect(closed).toMatchObject({ code: 1009 });
      expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
    });
  });

  it('treats a retry with the same id as already committed without duplicating rows or unread', async () => {
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
    const bobState = await db
      .prepare('SELECT unread_count FROM conversation_user_state WHERE conversation_id = ? AND user_id = ?')
      .bind(CONVERSATION, BOB)
      .first<{ unread_count: number }>();
    expect(bobState?.unread_count).toBe(1);
  });

  it('rejects an id already used by another conversation message', async () => {
    const takenId = '99999999-9999-4999-8999-999999999999';
    await seedMessage(takenId, CONVERSATION, BOB, { senderDeviceId: bobDevice });
    const { ack } = await send(message({}, takenId));
    expect(ack).toMatchObject({ type: 'error', code: 'conflict' });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(1);
  });

  it('rolls back every write and reports send_failed when the insert fails', async () => {
    const { ack } = await send(message({ replyToId: 'missing-reply-id' }));

    expect(ack).toMatchObject({ type: 'error', code: 'send_failed' });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
    const conversation = await db
      .prepare('SELECT last_message_at, last_message_sender_id FROM conversations WHERE id = ?')
      .bind(CONVERSATION)
      .first<{ last_message_at: number | null; last_message_sender_id: string | null }>();
    expect(conversation).toEqual({ last_message_at: null, last_message_sender_id: null });
    const bobState = await db
      .prepare('SELECT unread_count FROM conversation_user_state WHERE conversation_id = ? AND user_id = ?')
      .bind(CONVERSATION, BOB)
      .first<{ unread_count: number }>();
    expect(bobState?.unread_count).toBe(0);
  });

  describe('media ownership', () => {
    it('accepts media that belongs to the sender and conversation', async () => {
      const mediaId = crypto.randomUUID();
      await seedMedia(mediaId, CONVERSATION, ALICE);

      const { ack } = await send(message({ mediaId }));

      expect(ack).toMatchObject({ status: 'sent' });
      const stored = await db
        .prepare('SELECT media_id FROM messages WHERE id = ?')
        .bind((message() as { id: string }).id)
        .first<{ media_id: string | null }>();
      expect(stored?.media_id).toBe(mediaId);
    });

    it('rejects media owned by another user', async () => {
      const mediaId = crypto.randomUUID();
      await seedMedia(mediaId, CONVERSATION, BOB);

      const { ack } = await send(message({ mediaId }));

      expect(ack).toMatchObject({ type: 'error', code: 'invalid_media' });
      expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
    });

    it('rejects media from another conversation', async () => {
      await seedConversation(OTHER_CONVERSATION, ALICE, CAROL);
      const mediaId = crypto.randomUUID();
      await seedMedia(mediaId, OTHER_CONVERSATION, ALICE);

      const { ack } = await send(message({ mediaId }));

      expect(ack).toMatchObject({ type: 'error', code: 'invalid_media' });
      expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
    });

    it('rejects already consumed media', async () => {
      const mediaId = crypto.randomUUID();
      await seedMedia(mediaId, CONVERSATION, ALICE, { consumed: true });

      const { ack } = await send(message({ mediaId }));

      expect(ack).toMatchObject({ type: 'error', code: 'invalid_media' });
      expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
    });
  });
});
