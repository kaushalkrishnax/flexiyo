import { beforeEach, describe, expect, it } from 'vitest';
import { cleanExpiredMessages } from '../src/services/expiry.js';
import { purgeExpiredMedia } from '../src/services/media_purge.js';
import {
  countRows,
  db,
  resetDatabase,
  seedConversation,
  seedDevice,
  seedUser,
  testEnv,
} from './support.js';

const ALICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const BOB = 'bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb';
const CONVERSATION = 'ffffffff-ffff-4fff-8fff-ffffffffffff';

function now(): number {
  return Math.floor(Date.now() / 1000);
}

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

async function flush(statements: D1PreparedStatement[], size = 100): Promise<void> {
  for (let i = 0; i < statements.length; i += size) {
    await db.batch(statements.slice(i, i + size));
  }
}

function mediaInsert(id: string, expiresAt: number): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO media
         (id, conversation_id, sender_id, kind, size, mime_type, r2_key, created_at, expires_at)
       VALUES (?, ?, ?, 'image', 10, 'image/png', ?, 0, ?)`,
    )
    .bind(id, CONVERSATION, ALICE, `media/${id}`, expiresAt);
}

function messageInsert(id: string, expiresAt: number | null): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO messages
         (id, conversation_id, sender_id, sender_device_id, message_type, version, is_unsent, created_at, expires_at)
       VALUES (?, ?, ?, ?, 'signal', 1, 0, 0, ?)`,
    )
    .bind(id, CONVERSATION, ALICE, aliceDevice, expiresAt);
}

async function setLastCleanup(timestamp: number): Promise<void> {
  await db
    .prepare(
      `INSERT INTO worker_meta (key, value) VALUES ('last_expiry_cleanup', ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    )
    .bind(String(timestamp))
    .run();
}

describe('purgeExpiredMedia', () => {
  it('deletes at most 200 expired rows per run, oldest first, with views and objects', async () => {
    const base = now() - 10_000;
    const ids: string[] = [];
    const statements: D1PreparedStatement[] = [];
    for (let i = 0; i < 201; i++) {
      const id = crypto.randomUUID();
      ids.push(id);
      statements.push(mediaInsert(id, base + i));
    }
    const futureId = crypto.randomUUID();
    statements.push(mediaInsert(futureId, now() + 3_600));
    await flush(statements);

    await db
      .prepare('INSERT INTO media_views (media_id, user_id, count, updated_at) VALUES (?, ?, 1, 0)')
      .bind(ids[0], BOB)
      .run();
    for (const id of [ids[0], ids[200], futureId]) {
      await testEnv.MEDIA.put(`media/${id}`, 'bytes');
    }

    await purgeExpiredMedia(db, testEnv);

    expect(await countRows('SELECT COUNT(*) AS n FROM media')).toBe(2);
    expect(await countRows('SELECT COUNT(*) AS n FROM media WHERE id = ?', ids[0])).toBe(0);
    expect(await countRows('SELECT COUNT(*) AS n FROM media WHERE id = ?', ids[200])).toBe(1);
    expect(await countRows('SELECT COUNT(*) AS n FROM media WHERE id = ?', futureId)).toBe(1);
    expect(await countRows('SELECT COUNT(*) AS n FROM media_views')).toBe(0);
    expect(await testEnv.MEDIA.get(`media/${ids[0]}`)).toBeNull();
    expect(await testEnv.MEDIA.get(`media/${ids[200]}`)).not.toBeNull();

    await purgeExpiredMedia(db, testEnv);
    expect(await countRows('SELECT COUNT(*) AS n FROM media')).toBe(1);
    expect(await testEnv.MEDIA.get(`media/${ids[200]}`)).toBeNull();
    expect(await testEnv.MEDIA.get(`media/${futureId}`)).not.toBeNull();
  });

  it('prunes usage rows older than 30 days and keeps recent ones', async () => {
    const day = (offset: number) =>
      new Date(Date.now() - offset * 86_400_000).toISOString().slice(0, 10);
    const oldDay = day(40);
    const recentDay = day(2);
    await db.batch([
      db
        .prepare('INSERT INTO daily_usage (user_id, day, bytes_up, bytes_down) VALUES (?, ?, 1, 1)')
        .bind(ALICE, oldDay),
      db
        .prepare('INSERT INTO daily_usage (user_id, day, bytes_up, bytes_down) VALUES (?, ?, 2, 2)')
        .bind(ALICE, recentDay),
    ]);

    await purgeExpiredMedia(db, testEnv);

    expect(await countRows('SELECT COUNT(*) AS n FROM daily_usage WHERE day = ?', oldDay)).toBe(0);
    expect(await countRows('SELECT COUNT(*) AS n FROM daily_usage WHERE day = ?', recentDay)).toBe(1);
  });
});

describe('cleanExpiredMessages', () => {
  it('skips the sweep inside the 60-second throttle window', async () => {
    await setLastCleanup(now());
    await flush([messageInsert(crypto.randomUUID(), now() - 1)]);

    await cleanExpiredMessages(testEnv);

    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(1);
  });

  it('deletes expired messages and their deliveries once the window elapsed', async () => {
    await setLastCleanup(now() - 61);
    const expired = crypto.randomUUID();
    const alive = crypto.randomUUID();
    await flush([
      messageInsert(expired, now() - 5),
      messageInsert(alive, now() + 3_600),
    ]);
    await db
      .prepare(
        `INSERT INTO message_deliveries
           (id, message_id, recipient_device_id, payload, message_type, created_at)
         VALUES (?, ?, ?, 'ct', 'signal', 0)`,
      )
      .bind(crypto.randomUUID(), expired, bobDevice)
      .run();

    await cleanExpiredMessages(testEnv);

    expect(await countRows('SELECT COUNT(*) AS n FROM messages WHERE id = ?', expired)).toBe(0);
    expect(await countRows('SELECT COUNT(*) AS n FROM messages WHERE id = ?', alive)).toBe(1);
    expect(await countRows('SELECT COUNT(*) AS n FROM message_deliveries')).toBe(0);

    const meta = await db
      .prepare(`SELECT value FROM worker_meta WHERE key = 'last_expiry_cleanup'`)
      .first<{ value: string }>();
    expect(Number(meta?.value)).toBeGreaterThanOrEqual(now() - 5);
  });

  it('bounds a sweep to 500 messages and resumes on the next run', async () => {
    await setLastCleanup(0);
    const base = now() - 10_000;
    const ids: string[] = [];
    const statements: D1PreparedStatement[] = [];
    for (let i = 0; i < 501; i++) {
      const id = crypto.randomUUID();
      ids.push(id);
      statements.push(messageInsert(id, base + i));
    }
    await flush(statements);

    await cleanExpiredMessages(testEnv);

    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(1);
    expect(await countRows('SELECT COUNT(*) AS n FROM messages WHERE id = ?', ids[0])).toBe(0);
    expect(await countRows('SELECT COUNT(*) AS n FROM messages WHERE id = ?', ids[500])).toBe(1);

    await setLastCleanup(0);
    await cleanExpiredMessages(testEnv);
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
  });
});
