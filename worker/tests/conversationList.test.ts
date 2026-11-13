import { SELF } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  conversationListQuery,
  parseScope,
} from '../src/services/conversationList.js';
import {
  db,
  resetDatabase,
  seedBlock,
  seedConversation,
  seedConversationKeyDevice,
  seedConversationKeyEpoch,
  seedUser,
  tokenFor,
} from './support.js';

const ALICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const BOB = 'bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb';
const CAROL = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const DAVE = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const NONCE = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const TAG = 'AAAAAAAAAAAAAAAAAAAAAA==';
const CIPHERTEXT = 'YWJj';

const placeholderCount = (sql: string) => (sql.match(/\?/g) || []).length;

async function api(
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

describe('conversation list query', () => {
  it('binds one value per placeholder for every scope', () => {
    for (const scope of ['inbox', 'requests', 'blocked', 'all'] as const) {
      const { sql, binds } = conversationListQuery('user-1', scope);
      expect(binds).toHaveLength(placeholderCount(sql));
    }
  });

  it('defaults unknown scopes to the inbox and parses known scopes', () => {
    expect(parseScope(new URL('https://x.test/api/conversations'))).toBe('inbox');
    expect(parseScope(new URL('https://x.test/api/conversations?scope=requests'))).toBe('requests');
    expect(parseScope(new URL('https://x.test/api/conversations?scope=blocked'))).toBe('blocked');
    expect(parseScope(new URL('https://x.test/api/conversations?scope=all'))).toBe('all');
    expect(parseScope(new URL('https://x.test/api/conversations?scope=bogus'))).toBe('inbox');
  });
});

describe('GET /api/conversations scopes and incremental state', () => {
  let aliceDevice = 0;
  let bobDevice = 0;
  let carolDevice = 0;
  let daveDevice = 0;

  const CONV_ACCEPTED = '11111111-1111-4111-8111-111111111111';
  const CONV_OUTGOING_REQ = '22222222-2222-4222-8222-222222222222';
  const CONV_INCOMING_REQ = '33333333-3333-4333-8333-333333333333';

  beforeEach(async () => {
    await resetDatabase();
    await seedUser(ALICE);
    await seedUser(BOB);
    await seedUser(CAROL);
    await seedUser(DAVE);
    aliceDevice = await seedConversationKeyDevice(ALICE, 'install-alice');
    bobDevice = await seedConversationKeyDevice(BOB, 'install-bob');
    carolDevice = await seedConversationKeyDevice(CAROL, 'install-carol');
    daveDevice = await seedConversationKeyDevice(DAVE, 'install-dave');

    await seedConversation(CONV_ACCEPTED, ALICE, BOB, { requestStatus: 'accepted' });
    await seedConversationKeyEpoch(CONV_ACCEPTED, 1, aliceDevice, [aliceDevice, bobDevice]);

    await seedConversation(CONV_OUTGOING_REQ, ALICE, CAROL, {
      requestStatus: 'pending',
      initiatedById: ALICE,
    });
    await seedConversationKeyEpoch(CONV_OUTGOING_REQ, 1, aliceDevice, [aliceDevice, carolDevice]);

    await seedConversation(CONV_INCOMING_REQ, ALICE, DAVE, {
      requestStatus: 'pending',
      initiatedById: DAVE,
    });
    await seedConversationKeyEpoch(CONV_INCOMING_REQ, 1, daveDevice, [aliceDevice, daveDevice]);
  });

  it('partitions accepted, outgoing requests, incoming requests, and blocked across scopes', async () => {
    // Send messages in all three conversations
    await api('POST', `/api/conversations/${CONV_ACCEPTED}/messages`, {
      userId: BOB,
      installation: 'install-bob',
      body: {
        encryptionVersion: 2,
        id: crypto.randomUUID(),
        ciphertext: CIPHERTEXT,
        nonce: NONCE,
        authTag: TAG,
        keyEpoch: 1,
        recipientId: ALICE,
      },
    });
    await api('POST', `/api/conversations/${CONV_OUTGOING_REQ}/messages`, {
      userId: ALICE,
      installation: 'install-alice',
      body: {
        encryptionVersion: 2,
        id: crypto.randomUUID(),
        ciphertext: CIPHERTEXT,
        nonce: NONCE,
        authTag: TAG,
        keyEpoch: 1,
        recipientId: CAROL,
      },
    });
    await api('POST', `/api/conversations/${CONV_INCOMING_REQ}/messages`, {
      userId: DAVE,
      installation: 'install-dave',
      body: {
        encryptionVersion: 2,
        id: crypto.randomUUID(),
        ciphertext: CIPHERTEXT,
        nonce: NONCE,
        authTag: TAG,
        keyEpoch: 1,
        recipientId: ALICE,
      },
    });

    const inbox = (await (await api('GET', '/api/conversations?scope=inbox')).json()) as Array<{
      id: string;
      unreadCount: number;
      lastMessageIsMine: boolean;
    }>;
    expect(inbox.map((c) => c.id).sort()).toEqual([CONV_ACCEPTED, CONV_OUTGOING_REQ]);
    expect(inbox.find((c) => c.id === CONV_ACCEPTED)).toMatchObject({
      unreadCount: 1,
      lastMessageIsMine: false,
    });
    expect(inbox.find((c) => c.id === CONV_OUTGOING_REQ)).toMatchObject({
      unreadCount: 0,
      lastMessageIsMine: true,
    });

    const requests = (await (await api('GET', '/api/conversations?scope=requests')).json()) as Array<{
      id: string;
      unreadCount: number;
    }>;
    expect(requests.map((c) => c.id)).toEqual([CONV_INCOMING_REQ]);
    expect(requests[0].unreadCount).toBe(1);

    const all = (await (await api('GET', '/api/conversations?scope=all')).json()) as {
      conversations: Array<{ id: string }>;
      requests: Array<{ id: string }>;
    };
    expect(all.conversations.map((c) => c.id).sort()).toEqual([CONV_ACCEPTED, CONV_OUTGOING_REQ]);
    expect(all.requests.map((c) => c.id)).toEqual([CONV_INCOMING_REQ]);

    // Blocking BOB moves CONV_ACCEPTED to blocked scope and excludes from inbox/all
    await seedBlock(ALICE, BOB);
    const blocked = (await (await api('GET', '/api/conversations?scope=blocked')).json()) as Array<{
      id: string;
    }>;
    expect(blocked.map((c) => c.id)).toEqual([CONV_ACCEPTED]);

    const afterBlockAll = (await (await api('GET', '/api/conversations?scope=all')).json()) as {
      conversations: Array<{ id: string }>;
      requests: Array<{ id: string }>;
    };
    expect(afterBlockAll.conversations.map((c) => c.id)).toEqual([CONV_OUTGOING_REQ]);
    expect(afterBlockAll.requests.map((c) => c.id)).toEqual([CONV_INCOMING_REQ]);
  });

  it('creates conversation_user_state rows on POST /api/conversations', async () => {
    const EVE = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
    await seedUser(EVE);

    const create = await api('POST', '/api/conversations', {
      userId: ALICE,
      body: { participantId: EVE },
    });
    expect(create.status).toBe(201);
    const body = (await create.json()) as { id: string };

    const states = await db
      .prepare('SELECT user_id, unread_count FROM conversation_user_state WHERE conversation_id = ? ORDER BY user_id')
      .bind(body.id)
      .all<{ user_id: string; unread_count: number }>();
    expect(states.results).toEqual([
      { user_id: ALICE, unread_count: 0 },
      { user_id: EVE, unread_count: 0 },
    ]);
  });
});
