import { SELF } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  countRows,
  db,
  resetDatabase,
  seedBlock,
  seedConversation,
  seedConversationKeyDevice,
  seedConversationKeyEpoch,
  seedMessage,
  seedUser,
  testEnv,
  tokenFor,
} from './support.js';

const ALICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const BOB = 'bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb';
const CAROL = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const CONVERSATION = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const OTHER_CONVERSATION = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const NONCE = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const TAG = 'AAAAAAAAAAAAAAAAAAAAAA==';
const CIPHERTEXT = 'YWJj';
const UPDATED_CIPHERTEXT = 'ZGVm';

let aliceDevice = 0;
let bobDevice = 0;

beforeEach(async () => {
  await resetDatabase();
  await seedUser(ALICE);
  await seedUser(BOB);
  await seedUser(CAROL);
  aliceDevice = await seedConversationKeyDevice(ALICE, 'install-alice');
  bobDevice = await seedConversationKeyDevice(BOB, 'install-bob');
  await seedConversationKeyDevice(CAROL, 'install-carol');
  await seedConversation(CONVERSATION, ALICE, BOB);
  await seedConversationKeyEpoch(CONVERSATION, 1, aliceDevice, [aliceDevice, bobDevice]);
});

interface ApiOptions {
  userId?: string;
  installation?: string;
  body?: unknown;
}

async function api(
  method: string,
  path: string,
  options: ApiOptions = {},
): Promise<Response> {
  const headers = new Headers({ 'Content-Type': 'application/json' });
  headers.set('Authorization', `Bearer ${await tokenFor(options.userId ?? ALICE)}`);
  if (options.installation !== undefined) {
    headers.set('X-Installation-Id', options.installation);
  }
  return SELF.fetch(
    new Request(`https://example.com${path}`, {
      method,
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    }),
  );
}

function sendBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    encryptionVersion: 2,
    id: crypto.randomUUID(),
    ciphertext: CIPHERTEXT,
    nonce: NONCE,
    authTag: TAG,
    keyEpoch: 1,
    recipientId: BOB,
    ...overrides,
  };
}

describe('POST /api/conversations/:id/messages', () => {
  it('commits the v2 message, returns it, and updates conversation state', async () => {
    const body = sendBody();
    const response = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body,
    });

    expect(response.status).toBe(201);
    const created = (await response.json()) as Record<string, unknown>;
    expect(created).toMatchObject({
      id: body.id,
      conversationId: CONVERSATION,
      senderId: ALICE,
      senderDeviceId: aliceDevice,
      encryptionVersion: 2,
      ciphertext: CIPHERTEXT,
      nonce: NONCE,
      authTag: TAG,
      keyEpoch: 1,
      messageType: 'signal',
      version: 1,
      isUnsent: false,
      isSentByMe: true,
    });

    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(1);
    const conv = await db
      .prepare('SELECT last_message_at, last_message_sender_id FROM conversations WHERE id = ?')
      .bind(CONVERSATION)
      .first<{ last_message_at: number | null; last_message_sender_id: string | null }>();
    expect(conv?.last_message_at).toBeGreaterThan(0);
    expect(conv?.last_message_sender_id).toBe(ALICE);

    const bobState = await db
      .prepare('SELECT unread_count FROM conversation_user_state WHERE conversation_id = ? AND user_id = ?')
      .bind(CONVERSATION, BOB)
      .first<{ unread_count: number }>();
    expect(bobState?.unread_count).toBe(1);
  });

  it('reports a retry of the same id as already committed without double-counting unread', async () => {
    const body = sendBody();

    const first = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body,
    });
    expect(first.status).toBe(201);

    const retry = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body,
    });
    expect(retry.status).toBe(200);
    expect(await retry.json()).toEqual({ id: body.id, status: 'already_committed' });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(1);

    const bobState = await db
      .prepare('SELECT unread_count FROM conversation_user_state WHERE conversation_id = ? AND user_id = ?')
      .bind(CONVERSATION, BOB)
      .first<{ unread_count: number }>();
    expect(bobState?.unread_count).toBe(1);
  });

  it('rejects a legacy v1 payloads body', async () => {
    const response = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body: {
        id: crypto.randomUUID(),
        payloads: [{ deviceId: bobDevice, ciphertext: 'ct', messageType: 'signal' }],
        messageType: 'signal',
        recipientId: BOB,
      },
    });
    expect(response.status).toBe(400);
  });

  it('rejects an id used by another sender', async () => {
    const takenId = crypto.randomUUID();
    await seedMessage(takenId, CONVERSATION, BOB, { senderDeviceId: bobDevice });
    const response = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body: sendBody({ id: takenId }),
    });
    expect(response.status).toBe(409);
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(1);
  });

  it('rejects a send from a non-member', async () => {
    await seedConversation(OTHER_CONVERSATION, BOB, CAROL);
    const response = await api('POST', `/api/conversations/${OTHER_CONVERSATION}/messages`, {
      installation: 'install-alice',
      body: sendBody({ recipientId: CAROL }),
    });
    expect(response.status).toBe(404);
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
  });

  it('rejects a mismatched recipient', async () => {
    const response = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body: sendBody({ recipientId: CAROL }),
    });
    expect(response.status).toBe(400);
  });

  it('rejects blocked conversations in both directions', async () => {
    await seedBlock(BOB, ALICE);
    const blockedByPeer = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body: sendBody(),
    });
    expect(blockedByPeer.status).toBe(403);

    await resetDatabase();
    await seedUser(ALICE);
    await seedUser(BOB);
    aliceDevice = await seedConversationKeyDevice(ALICE, 'install-alice');
    bobDevice = await seedConversationKeyDevice(BOB, 'install-bob');
    await seedConversation(CONVERSATION, ALICE, BOB);
    await seedConversationKeyEpoch(CONVERSATION, 1, aliceDevice, [aliceDevice, bobDevice]);
    await seedBlock(ALICE, BOB);

    const blockedBySender = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body: sendBody(),
    });
    expect(blockedBySender.status).toBe(403);
  });

  it('rejects the recipient until the request is accepted', async () => {
    await db
      .prepare('UPDATE conversations SET request_status = ?, initiated_by_id = ? WHERE id = ?')
      .bind('pending', ALICE, CONVERSATION)
      .run();

    const response = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      userId: BOB,
      installation: 'install-bob',
      body: sendBody({ recipientId: ALICE }),
    });
    expect(response.status).toBe(403);
  });

  it('allows the initiator exactly one pending-request message', async () => {
    await db
      .prepare('UPDATE conversations SET request_status = ?, initiated_by_id = ? WHERE id = ?')
      .bind('pending', ALICE, CONVERSATION)
      .run();

    const first = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body: sendBody(),
    });
    expect(first.status).toBe(201);

    const second = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body: sendBody(),
    });
    expect(second.status).toBe(409);
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(1);
  });

  it('requires an active registered v2 sender installation', async () => {
    const missing = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      body: sendBody(),
    });
    expect(missing.status).toBe(403);

    const unknown = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-nobody',
      body: sendBody(),
    });
    expect(unknown.status).toBe(403);

    await db.prepare("UPDATE devices SET status = 'disabled' WHERE id = ?").bind(aliceDevice).run();
    const disabled = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body: sendBody(),
    });
    expect(disabled.status).toBe(403);
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
  });

  it('rejects when a recipient has no active devices or is missing a key envelope', async () => {
    await db.prepare("UPDATE devices SET status = 'disabled' WHERE user_id = ?").bind(BOB).run();
    const noRecipient = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body: sendBody(),
    });
    expect(noRecipient.status).toBe(409);

    await db.prepare("UPDATE devices SET status = 'active' WHERE user_id = ?").bind(BOB).run();
    await seedConversationKeyDevice(BOB, 'install-bob-2');
    const missingEnvelope = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body: sendBody(),
    });
    expect(missingEnvelope.status).toBe(409);
    expect(await missingEnvelope.json()).toMatchObject({
      error: 'conversation_keys_not_provisioned',
    });
  });

  it('validates the body and auth', async () => {
    const badId = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body: sendBody({ id: 'not-a-uuid' }),
    });
    expect(badId.status).toBe(400);

    const empty = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body: sendBody({ ciphertext: '' }),
    });
    expect(empty.status).toBe(400);

    const noAuth = await SELF.fetch(
      new Request(`https://example.com/api/conversations/${CONVERSATION}/messages`, {
        method: 'POST',
        body: JSON.stringify(sendBody()),
      }),
    );
    expect(noAuth.status).toBe(401);
  });
});

describe('GET /api/conversations/:id/messages', () => {
  async function postMessage(): Promise<string> {
    const body = sendBody();
    const response = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body,
    });
    expect(response.status).toBe(201);
    return body.id as string;
  }

  it('returns the conversation-key message for both participants', async () => {
    const messageId = await postMessage();

    const asBob = await api('GET', `/api/conversations/${CONVERSATION}/messages`, {
      userId: BOB,
      installation: 'install-bob',
    });
    expect(asBob.status).toBe(200);
    const bobMessages = (await asBob.json()) as Array<Record<string, unknown>>;
    expect(bobMessages).toHaveLength(1);
    expect(bobMessages[0]).toMatchObject({
      id: messageId,
      senderId: ALICE,
      encryptionVersion: 2,
      ciphertext: CIPHERTEXT,
      nonce: NONCE,
      authTag: TAG,
      keyEpoch: 1,
      isSentByMe: false,
    });

    const asAlice = await api('GET', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
    });
    const aliceMessages = (await asAlice.json()) as Array<Record<string, unknown>>;
    expect(aliceMessages).toHaveLength(1);
    expect(aliceMessages[0]).toMatchObject({
      id: messageId,
      ciphertext: CIPHERTEXT,
      isSentByMe: true,
    });
  });

  it('requires the requesting device', async () => {
    await postMessage();
    const response = await api('GET', `/api/conversations/${CONVERSATION}/messages`);
    expect(response.status).toBe(403);
  });

  it('hides locally deleted messages from the deleting user only', async () => {
    const messageId = await postMessage();

    const del = await api('POST', `/api/conversations/${CONVERSATION}/messages/delete-for-me`, {
      userId: BOB,
      installation: 'install-bob',
      body: { messageIds: [messageId] },
    });
    expect(del.status).toBe(200);
    expect(await del.json()).toEqual({ deleted: 1, scope: 'local' });

    const bobHistory = (await (
      await api('GET', `/api/conversations/${CONVERSATION}/messages`, {
        userId: BOB,
        installation: 'install-bob',
      })
    ).json()) as Array<Record<string, unknown>>;
    expect(bobHistory).toEqual([]);

    const aliceHistory = (await (
      await api('GET', `/api/conversations/${CONVERSATION}/messages`, {
        installation: 'install-alice',
      })
    ).json()) as Array<Record<string, unknown>>;
    expect(aliceHistory).toHaveLength(1);
    expect(await countRows('SELECT COUNT(*) AS n FROM local_deletions')).toBe(1);
  });

  it('accepts the maximum batch of 100 message ids for local deletion', async () => {
    const ids: string[] = [];
    for (let i = 0; i < 100; i++) {
      const id = crypto.randomUUID();
      ids.push(id);
      await seedMessage(id, CONVERSATION, ALICE, { senderDeviceId: aliceDevice });
    }

    const response = await api('POST', `/api/conversations/${CONVERSATION}/messages/delete-for-me`, {
      installation: 'install-alice',
      body: { messageIds: ids },
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ deleted: 100, scope: 'local' });
    expect(await countRows('SELECT COUNT(*) AS n FROM local_deletions')).toBe(100);
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(100);
  });

  it('does not leak messages from other conversations', async () => {
    await postMessage();
    await seedConversation(OTHER_CONVERSATION, BOB, CAROL);

    const response = await api('GET', `/api/conversations/${OTHER_CONVERSATION}/messages`, {
      userId: BOB,
      installation: 'install-bob',
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual([]);
  });
});

describe('PATCH /api/conversations/:id/messages/:messageId', () => {
  it('edits a v2 message and increments its version', async () => {
    const body = sendBody();
    const sent = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body,
    });
    expect(sent.status).toBe(201);

    const editRes = await api('PATCH', `/api/conversations/${CONVERSATION}/messages/${body.id}`, {
      installation: 'install-alice',
      body: {
        encryptionVersion: 2,
        ciphertext: UPDATED_CIPHERTEXT,
        nonce: NONCE,
        authTag: TAG,
        keyEpoch: 1,
        version: 1,
      },
    });
    expect(editRes.status).toBe(200);
    expect(await editRes.json()).toMatchObject({
      id: body.id,
      ciphertext: UPDATED_CIPHERTEXT,
      encryptionVersion: 2,
      version: 2,
    });

    const staleEdit = await api('PATCH', `/api/conversations/${CONVERSATION}/messages/${body.id}`, {
      installation: 'install-alice',
      body: {
        encryptionVersion: 2,
        ciphertext: CIPHERTEXT,
        nonce: NONCE,
        authTag: TAG,
        keyEpoch: 1,
        version: 1,
      },
    });
    expect(staleEdit.status).toBe(409);

    const v1Edit = await api('PATCH', `/api/conversations/${CONVERSATION}/messages/${body.id}`, {
      installation: 'install-alice',
      body: {
        payloads: [{ deviceId: bobDevice, ciphertext: 'ct' }],
        version: 2,
      },
    });
    expect(v1Edit.status).toBe(400);
  });
});

describe('POST /api/conversations/:id/read', () => {
  it('marks peer messages delivered/read and updates conversation_user_state', async () => {
    const body = sendBody();
    await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body,
    });

    const response = await api('POST', `/api/conversations/${CONVERSATION}/read`, {
      userId: BOB,
      installation: 'install-bob',
    });
    expect(response.status).toBe(200);
    const payload = (await response.json()) as { read: boolean; readAt: number };
    expect(payload.read).toBe(true);
    expect(payload.readAt).toBeGreaterThan(0);

    const stored = await db
      .prepare('SELECT delivered_at, read_at FROM messages WHERE id = ?')
      .bind(body.id as string)
      .first<{ delivered_at: number | null; read_at: number | null }>();
    expect(stored?.delivered_at).toBeGreaterThan(0);
    expect(stored?.read_at).toBe(payload.readAt);

    const aliceState = await db
      .prepare('SELECT peer_seen_at FROM conversation_user_state WHERE conversation_id = ? AND user_id = ?')
      .bind(CONVERSATION, ALICE)
      .first<{ peer_seen_at: number | null }>();
    expect(aliceState?.peer_seen_at).toBe(payload.readAt);

    const bobState = await db
      .prepare('SELECT unread_count, last_read_at FROM conversation_user_state WHERE conversation_id = ? AND user_id = ?')
      .bind(CONVERSATION, BOB)
      .first<{ unread_count: number; last_read_at: number | null }>();
    expect(bobState).toEqual({ unread_count: 0, last_read_at: payload.readAt });
  });

  it('does not send receipts for pending or blocked conversations', async () => {
    const body = sendBody();
    await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body,
    });

    await db
      .prepare('UPDATE conversations SET request_status = ? WHERE id = ?')
      .bind('pending', CONVERSATION)
      .run();
    const pending = await api('POST', `/api/conversations/${CONVERSATION}/read`, {
      userId: BOB,
      installation: 'install-bob',
    });
    expect(await pending.json()).toEqual({ read: false, reason: 'pending_request' });

    await db
      .prepare('UPDATE conversations SET request_status = ?, disappearing_timer = 0 WHERE id = ?')
      .bind('accepted', CONVERSATION)
      .run();
    await seedBlock(ALICE, BOB);
    const blocked = await api('POST', `/api/conversations/${CONVERSATION}/read`, {
      userId: BOB,
      installation: 'install-bob',
    });
    expect(await blocked.json()).toEqual({ read: false, reason: 'blocked' });

    const stored = await db
      .prepare('SELECT read_at FROM messages WHERE id = ?')
      .bind(body.id as string)
      .first<{ read_at: number | null }>();
    expect(stored?.read_at).toBeNull();
  });

  it('deletes the message immediately when the disappearing timer is -1 and resets state cleanly', async () => {
    await db
      .prepare('UPDATE conversations SET disappearing_timer = -1 WHERE id = ?')
      .bind(CONVERSATION)
      .run();
    const body = sendBody();
    const send = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body,
    });
    expect(send.status).toBe(201);

    const response = await api('POST', `/api/conversations/${CONVERSATION}/read`, {
      userId: BOB,
      installation: 'install-bob',
    });
    expect(response.status).toBe(200);
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);

    const bobState = await db
      .prepare('SELECT unread_count FROM conversation_user_state WHERE conversation_id = ? AND user_id = ?')
      .bind(CONVERSATION, BOB)
      .first<{ unread_count: number }>();
    expect(bobState?.unread_count).toBe(0);

    const aliceState = await db
      .prepare('SELECT peer_seen_at FROM conversation_user_state WHERE conversation_id = ? AND user_id = ?')
      .bind(CONVERSATION, ALICE)
      .first<{ peer_seen_at: number | null }>();
    expect(aliceState?.peer_seen_at).toBeNull();

    const conv = await db
      .prepare('SELECT last_message_at, last_message_sender_id FROM conversations WHERE id = ?')
      .bind(CONVERSATION)
      .first<{ last_message_at: number | null; last_message_sender_id: string | null }>();
    expect(conv).toEqual({ last_message_at: null, last_message_sender_id: null });
  });

  it('arms expires_at for more than 100 messages in one read', async () => {
    await db
      .prepare('UPDATE conversations SET disappearing_timer = 300 WHERE id = ?')
      .bind(CONVERSATION)
      .run();

    const statements: D1PreparedStatement[] = [];
    for (let i = 0; i < 101; i++) {
      const id = crypto.randomUUID();
      statements.push(
        db
          .prepare(
            `INSERT INTO messages
               (id, conversation_id, sender_id, sender_device_id, message_type, version, is_unsent, created_at,
                ciphertext, nonce, auth_tag, key_epoch)
             VALUES (?, ?, ?, ?, 'signal', 1, 0, 0, ?, ?, ?, 1)`,
          )
          .bind(id, CONVERSATION, ALICE, aliceDevice, CIPHERTEXT, NONCE, TAG),
      );
    }
    await db.batch(statements);

    const response = await api('POST', `/api/conversations/${CONVERSATION}/read`, {
      userId: BOB,
      installation: 'install-bob',
    });
    expect(response.status).toBe(200);

    const armed = await countRows(
      'SELECT COUNT(*) AS n FROM messages WHERE expires_at IS NOT NULL',
    );
    expect(armed).toBe(101);
    const range = await db
      .prepare('SELECT MIN(expires_at) AS min, MAX(expires_at) AS max FROM messages')
      .first<{ min: number; max: number }>();
    const now = Math.floor(Date.now() / 1000);
    expect(range?.min).toBeGreaterThanOrEqual(now + 295);
    expect(range?.max).toBeLessThanOrEqual(now + 305);
  });
});

describe('DELETE /api/conversations/:id/messages/:messageId', () => {
  function mediaRow(id: string, r2Key: string) {
    return db
      .prepare(
        `INSERT INTO media
           (id, conversation_id, sender_id, kind, view_policy, size, mime_type, r2_key, created_at, expires_at)
         VALUES (?, ?, ?, 'image', 'unlimited', 10, 'image/png', ?, 0, 9999999999)`,
      )
      .bind(id, CONVERSATION, ALICE, r2Key);
  }

  async function sendMediaMessage(): Promise<{ messageId: string; mediaId: string; r2Key: string }> {
    const mediaId = crypto.randomUUID();
    const r2Key = `media/${crypto.randomUUID()}`;
    await mediaRow(mediaId, r2Key).run();
    await testEnv.MEDIA.put(r2Key, 'bytes');

    const body = sendBody({ mediaId });
    const response = await api('POST', `/api/conversations/${CONVERSATION}/messages`, {
      installation: 'install-alice',
      body,
    });
    expect(response.status).toBe(201);
    return { messageId: body.id as string, mediaId, r2Key };
  }

  it('unsends the message, purges its media from R2, and resets conversation state', async () => {
    const { messageId, mediaId, r2Key } = await sendMediaMessage();

    const response = await api('DELETE', `/api/conversations/${CONVERSATION}/messages/${messageId}`, {
      installation: 'install-alice',
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ deleted: true, scope: 'global' });

    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
    expect(await countRows('SELECT COUNT(*) AS n FROM media WHERE id = ?', mediaId)).toBe(0);
    expect(await testEnv.MEDIA.get(r2Key)).toBeNull();

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

  it('lets only the sender unsend', async () => {
    const { messageId } = await sendMediaMessage();

    const response = await api('DELETE', `/api/conversations/${CONVERSATION}/messages/${messageId}`, {
      userId: BOB,
      installation: 'install-bob',
    });
    expect(response.status).toBe(403);
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(1);
  });
});

describe('GET /api/conversations/:id/messages pagination', () => {
  async function seedTimeline(count: number): Promise<string[]> {
    const ids: string[] = [];
    for (let i = 1; i <= count; i += 1) {
      const id = crypto.randomUUID();
      ids.push(id);
      await seedMessage(id, CONVERSATION, ALICE, {
        senderDeviceId: aliceDevice,
        createdAt: i,
      });
    }
    return ids;
  }

  it('returns the latest page and an older page without duplicates', async () => {
    const ids = await seedTimeline(25);

    const first = await api('GET', `/api/conversations/${CONVERSATION}/messages?limit=10`, {
      installation: 'install-alice',
    });
    expect(first.status).toBe(200);
    const firstPage = (await first.json()) as Array<{ id: string }>;
    expect(firstPage.map((m) => m.id)).toEqual(ids.slice(15).reverse());

    const cursor = firstPage[firstPage.length - 1].id;
    const second = await api(
      'GET',
      `/api/conversations/${CONVERSATION}/messages?limit=10&before=${cursor}&beforeCreatedAt=16`,
      { installation: 'install-alice' },
    );
    expect(second.status).toBe(200);
    const secondPage = (await second.json()) as Array<{ id: string }>;
    expect(secondPage.map((m) => m.id)).toEqual(ids.slice(5, 15).reverse());
    expect(secondPage.some((m) => firstPage.some((p) => p.id === m.id))).toBe(false);
  });

  it('falls back to the client timestamp when the cursor row is gone', async () => {
    const ids = await seedTimeline(25);
    const cursor = ids[15];
    await db.prepare('DELETE FROM messages WHERE id = ?').bind(cursor).run();

    const withoutTimestamp = await api(
      'GET',
      `/api/conversations/${CONVERSATION}/messages?limit=10&before=${cursor}`,
      { installation: 'install-alice' },
    );
    expect(withoutTimestamp.status).toBe(404);

    const response = await api(
      'GET',
      `/api/conversations/${CONVERSATION}/messages?limit=10&before=${cursor}&beforeCreatedAt=16`,
      { installation: 'install-alice' },
    );
    expect(response.status).toBe(200);
    const page = (await response.json()) as Array<{ id: string }>;
    expect(page.map((m) => m.id)).toEqual(ids.slice(5, 15).reverse());
  });
});
