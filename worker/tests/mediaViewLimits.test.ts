import { SELF } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  countRows,
  db,
  resetDatabase,
  seedConversation,
  seedDevice,
  seedMedia,
  seedUser,
  testEnv,
  tokenFor,
} from './support.js';

const ALICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const BOB = 'bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb';
const CONVERSATION = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

async function getMedia(mediaId: string, userId = BOB): Promise<Response> {
  return SELF.fetch(
    new Request(`https://example.com/api/media/${mediaId}`, {
      headers: { Authorization: `Bearer ${await tokenFor(userId)}` },
    }),
  );
}

describe('view-limited media', () => {
  beforeEach(async () => {
    await resetDatabase();
    await seedUser(ALICE);
    await seedUser(BOB);
    await seedDevice(ALICE, 'install-alice');
    await seedDevice(BOB, 'install-bob');
    await seedConversation(CONVERSATION, ALICE, BOB);
  });

  it('serves view-once media to only one of two concurrent requests', async () => {
    const mediaId = crypto.randomUUID();
    const r2Key = `media/${mediaId}`;
    await seedMedia(mediaId, CONVERSATION, ALICE, { viewPolicy: 'once', r2Key });
    await testEnv.MEDIA.put(r2Key, 'ciphertext-bytes');

    const responses = await Promise.all([getMedia(mediaId), getMedia(mediaId)]);
    const statuses = responses.map((response) => response.status).sort();

    expect(statuses).toEqual([200, 410]);
    expect(await countRows('SELECT COUNT(*) AS n FROM media_views WHERE media_id = ?', mediaId)).toBe(1);
    expect(await countRows('SELECT consumed AS n FROM media WHERE id = ?', mediaId)).toBe(1);
    expect(await testEnv.MEDIA.get(r2Key)).toBeNull();
  });

  it('allows exactly two sequential views for view-twice media', async () => {
    const mediaId = crypto.randomUUID();
    const r2Key = `media/${mediaId}`;
    await seedMedia(mediaId, CONVERSATION, ALICE, { viewPolicy: 'twice', r2Key });
    await testEnv.MEDIA.put(r2Key, 'ciphertext-bytes');

    const first = await getMedia(mediaId);
    const second = await getMedia(mediaId);
    const third = await getMedia(mediaId);

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(third.status).toBe(410);
    expect(await countRows('SELECT count AS n FROM media_views WHERE media_id = ?', mediaId)).toBe(2);
  });

  it('does not consume a view when the daily download quota is exhausted', async () => {
    const mediaId = crypto.randomUUID();
    const r2Key = `media/${mediaId}`;
    await seedMedia(mediaId, CONVERSATION, ALICE, { viewPolicy: 'once', r2Key });
    await testEnv.MEDIA.put(r2Key, 'ciphertext-bytes');

    const day = new Date().toISOString().slice(0, 10);
    await db
      .prepare(
        `INSERT INTO daily_usage (user_id, day, bytes_up, bytes_down)
         VALUES (?, ?, 0, ?)`,
      )
      .bind(BOB, day, 300 * 1024 * 1024)
      .run();

    const response = await getMedia(mediaId);

    expect(response.status).toBe(429);
    expect(await countRows('SELECT COUNT(*) AS n FROM media_views WHERE media_id = ?', mediaId)).toBe(0);
    expect(await countRows('SELECT consumed AS n FROM media WHERE id = ?', mediaId)).toBe(0);
  });
});
