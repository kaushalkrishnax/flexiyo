import { SELF } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import { cleanExpiredMessages } from '../src/services/expiry.js';
import {
  countRows,
  db,
  resetDatabase,
  seedConversation,
  seedConversationKeyDevice,
  seedConversationKeyEpoch,
  seedUser,
  testEnv,
  tokenFor,
} from './support.js';

const ALICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const BOB = 'bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb';
const CONVERSATION = 'ffffffff-ffff-4fff-8fff-ffffffffffff';

const HISTORY = 1200;

function historyId(index: number): string {
  return `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`;
}

function unreadId(index: number): string {
  return `11111111-1111-4111-8111-${String(index).padStart(12, '0')}`;
}

const OWN_UNREAD = '22222222-2222-4222-8222-222222222222';

let aliceDevice = 0;
let bobDevice = 0;

interface HistoryRow {
  id: string;
  senderId: string;
  createdAt: number;
  readAt?: number | null;
  deliveredAt?: number | null;
  expiresAt?: number | null;
}

async function insertHistory(rows: HistoryRow[]): Promise<void> {
  const statements = rows.map((row) =>
    db
      .prepare(
        `INSERT INTO messages
           (id, conversation_id, sender_id, message_type, version, is_unsent, created_at,
            read_at, delivered_at, expires_at)
         VALUES (?, ?, ?, 'signal', 1, 0, ?, ?, ?, ?)`,
      )
      .bind(
        row.id,
        CONVERSATION,
        row.senderId,
        row.createdAt,
        row.readAt ?? null,
        row.deliveredAt ?? null,
        row.expiresAt ?? null,
      ),
  );
  for (let index = 0; index < statements.length; index += 100) {
    await db.batch(statements.slice(index, index + 100));
  }
}

/** `history` already-read messages plus `unread` peer messages at the tail. */
async function seedConversationHistory(
  unread: number,
  history = HISTORY,
): Promise<{ unreadIds: string[]; ownUnreadId: string | null }> {
  const rows: HistoryRow[] = [];
  for (let index = 0; index < history; index += 1) {
    rows.push({
      id: historyId(index),
      senderId: index % 2 === 0 ? ALICE : BOB,
      createdAt: index + 1,
      readAt: index + 1,
      deliveredAt: index + 1,
    });
  }
  const unreadIds: string[] = [];
  let ownUnreadId: string | null = null;
  for (let index = 0; index < unread; index += 1) {
    const id = unreadId(index);
    unreadIds.push(id);
    rows.push({ id, senderId: BOB, createdAt: history + index + 1 });
  }
  if (unread > 0) {
    ownUnreadId = OWN_UNREAD;
    rows.push({ id: ownUnreadId, senderId: ALICE, createdAt: history + unread + 1 });
  }
  await insertHistory(rows);
  await db.batch([
    db
      .prepare(
        `UPDATE conversations SET last_message_at = ?, last_message_sender_id = ? WHERE id = ?`,
      )
      .bind(
        history + unread + (unread > 0 ? 1 : 0),
        unread > 0 ? ALICE : BOB,
        CONVERSATION,
      ),
    db
      .prepare(
        `UPDATE conversation_user_state SET unread_count = ? WHERE conversation_id = ? AND user_id = ?`,
      )
      .bind(unread, CONVERSATION, ALICE),
    db
      .prepare(
        `UPDATE conversation_user_state SET unread_count = ? WHERE conversation_id = ? AND user_id = ?`,
      )
      .bind(unread, CONVERSATION, BOB),
  ]);
  return { unreadIds, ownUnreadId };
}

async function api(
  method: string,
  path: string,
  options: { userId?: string; body?: unknown; installation?: string } = {},
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

async function readConversation(userId = ALICE): Promise<Response> {
  return api('POST', `/api/conversations/${CONVERSATION}/read`, { userId, body: {} });
}

async function readState(
  userId: string,
): Promise<{ unread_count: number; last_read_at: number | null; peer_seen_at: number | null }> {
  const row = await db
    .prepare(
      `SELECT unread_count, last_read_at, peer_seen_at
       FROM conversation_user_state WHERE conversation_id = ? AND user_id = ?`,
    )
    .bind(CONVERSATION, userId)
    .first<{ unread_count: number; last_read_at: number | null; peer_seen_at: number | null }>();
  expect(row).toBeTruthy();
  return row!;
}

async function messageReceipts(
  ids: string[],
): Promise<Array<{ id: string; read_at: number | null; delivered_at: number | null; expires_at: number | null }>> {
  const rows = await db
    .prepare(
      `SELECT id, read_at, delivered_at, expires_at FROM messages
       WHERE id IN (${ids.map(() => '?').join(', ')}) ORDER BY id`,
    )
    .bind(...ids)
    .all<{ id: string; read_at: number | null; delivered_at: number | null; expires_at: number | null }>();
  return rows.results ?? [];
}

beforeEach(async () => {
  await resetDatabase();
  await seedUser(ALICE);
  await seedUser(BOB);
  aliceDevice = await seedConversationKeyDevice(ALICE, 'install-alice');
  bobDevice = await seedConversationKeyDevice(BOB, 'install-bob');
  await seedConversation(CONVERSATION, ALICE, BOB);
  await seedConversationKeyEpoch(CONVERSATION, 1, aliceDevice, [aliceDevice, bobDevice]);
});

describe('read receipts over a large message history', () => {
  it('marks only unread peer messages read and keeps receipts + counters consistent', async () => {
    const { unreadIds, ownUnreadId } = await seedConversationHistory(3);

    const response = await readConversation();
    expect(response.status).toBe(200);
    const body = (await response.json()) as { read: boolean; readAt: number };
    expect(body.read).toBe(true);

    const receipts = await messageReceipts([...unreadIds, ownUnreadId!]);
    const byId = new Map(receipts.map((row) => [row.id, row]));
    for (const id of unreadIds) {
      expect(byId.get(id)).toMatchObject({
        read_at: body.readAt,
        delivered_at: body.readAt,
      });
    }
    // The reader's own message is never a read receipt.
    expect(byId.get(ownUnreadId!)).toMatchObject({ read_at: null, delivered_at: null });

    expect(await readState(ALICE)).toEqual({
      unread_count: 0,
      last_read_at: body.readAt,
      peer_seen_at: null,
    });
    expect(await readState(BOB)).toMatchObject({ peer_seen_at: body.readAt });
  });

  it('applies read state per account so a second device sees the same receipts', async () => {
    const { unreadIds } = await seedConversationHistory(1);
    await seedConversationKeyDevice(ALICE, 'install-alice-second');

    const { readAt } = (await (await readConversation()).json()) as { readAt: number };

    const detail = await api('GET', `/api/conversations/${CONVERSATION}`);
    expect(await detail.json()).toMatchObject({ unreadCount: 0, peerSeenAt: null });

    const history = await api('GET', `/api/conversations/${CONVERSATION}/messages?limit=5`, {
      installation: 'install-alice-second',
    });
    const messages = (await history.json()) as Array<{ id: string; readAt: number | null }>;
    const unreadMessage = messages.find((message) => message.id === unreadIds[0]);
    expect(unreadMessage?.readAt).toBe(readAt);

    const bobDetail = await api('GET', `/api/conversations/${CONVERSATION}`, { userId: BOB });
    expect(await bobDetail.json()).toMatchObject({ peerSeenAt: readAt });
  });

  it('is idempotent for repeated read requests and does not re-stamp receipts', async () => {
    const { unreadIds } = await seedConversationHistory(2);

    const first = (await (await readConversation()).json()) as { readAt: number };
    const afterFirst = await readState(ALICE);
    const second = (await (await readConversation()).json()) as { read: boolean; readAt: number };
    const afterSecond = await readState(ALICE);

    expect(second.read).toBe(true);
    expect(afterSecond).toEqual(afterFirst);
    expect(afterSecond.last_read_at).toBe(first.readAt);

    const receipts = await messageReceipts(unreadIds);
    for (const row of receipts) expect(row.read_at).toBe(first.readAt);
  });

  it('treats a conversation with no unread messages as read and repairs a drifted counter', async () => {
    await seedConversationHistory(0);
    await db
      .prepare(
        `UPDATE conversation_user_state SET unread_count = 7 WHERE conversation_id = ? AND user_id = ?`,
      )
      .bind(CONVERSATION, ALICE)
      .run();

    const before = await db
      .prepare(
        `SELECT MAX(read_at) AS read_at FROM messages WHERE conversation_id = ?`,
      )
      .bind(CONVERSATION)
      .first<{ read_at: number | null }>();

    const response = await readConversation();
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ read: true });

    expect((await readState(ALICE)).unread_count).toBe(0);
    const after = await db
      .prepare(`SELECT MAX(read_at) AS read_at FROM messages WHERE conversation_id = ?`)
      .bind(CONVERSATION)
      .first<{ read_at: number | null }>();
    expect(after?.read_at).toBe(before?.read_at ?? null);
    expect(await countRows('SELECT COUNT(*) AS n FROM messages WHERE read_at IS NULL')).toBe(0);
  });

  it('arms disappearing messages only for the messages it newly read', async () => {
    await db
      .prepare('UPDATE conversations SET disappearing_timer = 600 WHERE id = ?')
      .bind(CONVERSATION)
      .run();
    const { unreadIds } = await seedConversationHistory(2);

    const { readAt } = (await (await readConversation()).json()) as { readAt: number };
    const receipts = await messageReceipts(unreadIds);
    for (const row of receipts) {
      expect(row.read_at).toBe(readAt);
      expect(row.expires_at).toBe(readAt + 600);
    }

    const oldRead = await db
      .prepare('SELECT expires_at FROM messages WHERE id = ?')
      .bind(historyId(0))
      .first<{ expires_at: number | null }>();
    expect(oldRead?.expires_at).toBeNull();
  });

  it('deletes on read when the disappearing timer is -1 and clears the counter once', async () => {
    await db
      .prepare('UPDATE conversations SET disappearing_timer = -1 WHERE id = ?')
      .bind(CONVERSATION)
      .run();
    const { unreadIds } = await seedConversationHistory(2);

    await readConversation();

    expect(await countRows('SELECT COUNT(*) AS n FROM messages WHERE read_at IS NULL')).toBe(1);
    for (const id of unreadIds) {
      expect(await countRows('SELECT COUNT(*) AS n FROM messages WHERE id = ?', id)).toBe(0);
    }
    expect((await readState(ALICE)).unread_count).toBe(0);
    // The remaining unread row is the reader's own message; it is not a receipt target.
    expect(
      await countRows('SELECT COUNT(*) AS n FROM messages WHERE id = ?', OWN_UNREAD),
    ).toBe(1);
  });
});

describe('read receipt query plan and rows read', () => {
  it('uses one index seek and scans only the unread set', async () => {
    await seedConversationHistory(3);

    const plan = await db
      .prepare(
        `EXPLAIN QUERY PLAN
         UPDATE messages
         SET delivered_at = COALESCE(delivered_at, 1), read_at = 1
         WHERE conversation_id = ? AND sender_id = ? AND is_unsent = 0 AND read_at IS NULL
         RETURNING id`,
      )
      .bind(CONVERSATION, BOB)
      .all<{ detail: string }>();
    const detail = (plan.results ?? []).map((row) => row.detail).join('\n');

    expect(detail).toContain('idx_messages_conv_sender_read');
    expect(detail).toMatch(/conversation_id=\?/);
    expect(detail).toMatch(/sender_id=\?/);
    expect(detail).toMatch(/read_at=\?/);
    expect(detail).not.toMatch(/\bSCAN\b/);
  });

  it('reads rows on the order of the unread count, not the history length', async () => {
    await seedConversationHistory(3);

    const unreadUpdate = await db
      .prepare(
        `UPDATE messages
         SET delivered_at = COALESCE(delivered_at, 9), read_at = 9
         WHERE conversation_id = ? AND sender_id = ? AND is_unsent = 0 AND read_at IS NULL
         RETURNING id`,
      )
      .bind(CONVERSATION, BOB)
      .all<{ id: string }>();

    expect(unreadUpdate.results?.length).toBe(3);
    expect(unreadUpdate.meta.rows_read).toBeLessThanOrEqual(20);

    // The previous predicate shape (`sender_id != ?`) degrades to a range scan
    // over the whole conversation even when almost everything is read.
    const previousShape = await db
      .prepare(
        `SELECT id FROM messages
         WHERE conversation_id = ? AND sender_id != ? AND is_unsent = 0 AND read_at IS NULL`,
      )
      .bind(CONVERSATION, ALICE)
      .all<{ id: string }>();
    expect(previousShape.meta.rows_read).toBeGreaterThan(HISTORY);
  });

  it('returns no rows and reads nothing when the conversation has no unread messages', async () => {
    await seedConversationHistory(0);

    const result = await db
      .prepare(
        `UPDATE messages
         SET delivered_at = COALESCE(delivered_at, 9), read_at = 9
         WHERE conversation_id = ? AND sender_id = ? AND is_unsent = 0 AND read_at IS NULL
         RETURNING id`,
      )
      .bind(CONVERSATION, BOB)
      .all<{ id: string }>();

    expect(result.results).toEqual([]);
    expect(result.meta.rows_read).toBeLessThanOrEqual(5);
  });
});

describe('deletion and expiration over a large message history', () => {
  it('decrements unread state and re-derives the last message without scanning history', async () => {
    const { unreadIds } = await seedConversationHistory(3);

    const idsPayload = JSON.stringify([unreadIds[2]]);
    const impactPlan = await db
      .prepare(
        `EXPLAIN QUERY PLAN
         SELECT m.sender_id AS sender_id,
                SUM(CASE WHEN m.read_at IS NULL THEN 1 ELSE 0 END) AS unread_deleted,
                SUM(CASE WHEN m.read_at IS NOT NULL THEN 1 ELSE 0 END) AS read_deleted
         FROM json_each(?) ids
         CROSS JOIN messages m
         WHERE m.id = ids.value AND m.conversation_id = ? AND m.is_unsent = 0
         GROUP BY m.sender_id`,
      )
      .bind(idsPayload, CONVERSATION)
      .all<{ detail: string }>();
    const impactDetail = (impactPlan.results ?? []).map((row) => row.detail).join('\n');
    expect(impactDetail).toContain('sqlite_autoindex_messages_1');
    expect(impactDetail).not.toMatch(/idx_messages_conv_created/);

    const impact = await db
      .prepare(
        `SELECT m.sender_id AS sender_id,
                SUM(CASE WHEN m.read_at IS NULL THEN 1 ELSE 0 END) AS unread_deleted,
                SUM(CASE WHEN m.read_at IS NOT NULL THEN 1 ELSE 0 END) AS read_deleted
         FROM json_each(?) ids
         CROSS JOIN messages m
         WHERE m.id = ids.value AND m.conversation_id = ? AND m.is_unsent = 0
         GROUP BY m.sender_id`,
      )
      .bind(idsPayload, CONVERSATION)
      .all<{ sender_id: string; unread_deleted: number; read_deleted: number }>();
    expect(impact.meta.rows_read).toBeLessThanOrEqual(10);
    expect(impact.results).toEqual([{ sender_id: BOB, unread_deleted: 1, read_deleted: 0 }]);

    const unsend = await api(
      'DELETE',
      `/api/conversations/${CONVERSATION}/messages/${unreadIds[2]}`,
      { userId: BOB },
    );
    expect(unsend.status).toBe(200);

    expect((await readState(ALICE)).unread_count).toBe(2);
    const conversation = await db
      .prepare('SELECT last_message_at, last_message_sender_id FROM conversations WHERE id = ?')
      .bind(CONVERSATION)
      .first<{ last_message_at: number | null; last_message_sender_id: string | null }>();
    // The reader's own message is now the newest surviving message.
    expect(conversation).toEqual({
      last_message_at: HISTORY + 4,
      last_message_sender_id: ALICE,
    });
  });

  it('keeps unread counts consistent when an unread message expires', async () => {
    const { unreadIds } = await seedConversationHistory(2);
    const nowSeconds = Math.floor(Date.now() / 1000);
    await db
      .prepare('UPDATE messages SET expires_at = ? WHERE id = ?')
      .bind(nowSeconds - 5, unreadIds[0])
      .run();
    await db
      .prepare(
        `INSERT INTO worker_meta (key, value) VALUES ('last_expiry_cleanup', ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
      )
      .bind(String(0))
      .run();

    await cleanExpiredMessages(testEnv);

    expect(await countRows('SELECT COUNT(*) AS n FROM messages WHERE id = ?', unreadIds[0])).toBe(0);
    expect(await countRows('SELECT COUNT(*) AS n FROM messages WHERE id = ?', unreadIds[1])).toBe(1);
    expect((await readState(ALICE)).unread_count).toBe(1);
    expect(
      await countRows('SELECT COUNT(*) AS n FROM conversation_user_state WHERE conversation_id = ?', CONVERSATION),
    ).toBe(2);
  });

  it('validates delete-for-me against a large history without a conversation scan', async () => {
    const { unreadIds } = await seedConversationHistory(2);
    const payload = [unreadIds[0], historyId(5)];

    const lookup = await db
      .prepare(
        `SELECT m.id AS id
         FROM json_each(?) ids
         CROSS JOIN messages m
         WHERE m.id = ids.value AND m.conversation_id = ?`,
      )
      .bind(JSON.stringify(payload), CONVERSATION)
      .all<{ id: string }>();
    expect(lookup.results?.length).toBe(2);
    expect(lookup.meta.rows_read).toBeLessThanOrEqual(10);

    const response = await api(
      'POST',
      `/api/conversations/${CONVERSATION}/messages/delete-for-me`,
      { body: { messageIds: payload } },
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ deleted: 2, scope: 'local' });

    const missing = await api(
      'POST',
      `/api/conversations/${CONVERSATION}/messages/delete-for-me`,
      {
        body: {
          messageIds: [unreadIds[1], '33333333-3333-4333-8333-333333333333'],
        },
      },
    );
    expect(missing.status).toBe(404);
  });
});
