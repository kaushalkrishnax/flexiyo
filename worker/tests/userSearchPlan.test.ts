import { SELF } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import { db, resetDatabase, tokenFor } from './support.js';

const SEEKER = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const USER_COUNT = 3000;

// Mirrors `usersRouter.get('/search')` after Drizzle compiles the builder call.
const SEARCH_SQL = `SELECT id, username FROM users WHERE username LIKE ? AND id != ? LIMIT 20`;

type ExplainRow = { detail: string };

async function seedUsers(): Promise<void> {
  const statements = [db.prepare(
    `INSERT INTO users (id, username, password_hash, created_at) VALUES (?, ?, 'x', 0)`,
  ).bind(SEEKER, 'seeker')];
  for (let index = 0; index < USER_COUNT; index += 1) {
    const suffix = String(index).padStart(4, '0');
    statements.push(
      db.prepare(
        `INSERT INTO users (id, username, password_hash, created_at) VALUES (?, ?, 'x', 0)`,
      ).bind(`member-${suffix}`, `member${suffix}`),
    );
  }
  for (let index = 0; index < statements.length; index += 100) {
    await db.batch(statements.slice(index, index + 100));
  }
}

async function search(query: string): Promise<Response> {
  return SELF.fetch(
    new Request(`https://example.com/api/users/search?q=${encodeURIComponent(query)}`, {
      headers: { Authorization: `Bearer ${await tokenFor(SEEKER)}` },
    }),
  );
}

beforeEach(async () => {
  await resetDatabase();
  await seedUsers();
});

describe('user prefix search plan', () => {
  it('seeks the case-insensitive username index instead of scanning users', async () => {
    const plan = await db
      .prepare(`EXPLAIN QUERY PLAN ${SEARCH_SQL}`)
      .bind('MEMBER0002%', SEEKER)
      .all<ExplainRow>();
    const details = (plan.results ?? []).map((row) => row.detail).join('\n');

    expect(details).toContain('idx_users_username_nocase');
    expect(details).not.toMatch(/SCAN users/);
  });

  it('reads a bounded number of rows for a prefix that matches nothing', async () => {
    const miss = await db
      .prepare(SEARCH_SQL)
      .bind('zzzz%', SEEKER)
      .all<{ id: string; username: string }>();

    expect(miss.results).toEqual([]);
    // A full scan would read all USER_COUNT + 1 rows; the seek reads the
    // index range only, so the cost does not track table size.
    expect(miss.meta.rows_read).toBeLessThan(50);
  });

  it('stops at the page limit instead of reading the whole matching range', async () => {
    const hit = await db
      .prepare(SEARCH_SQL)
      .bind('member%', SEEKER)
      .all<{ id: string; username: string }>();

    expect(hit.results?.length).toBe(20);
    expect(hit.meta.rows_read).toBeLessThan(USER_COUNT);
  });
});

describe('user prefix search behaviour', () => {
  it('matches case-insensitively, excludes the caller, and caps the page', async () => {
    const response = await search('MEMBER');
    expect(response.status).toBe(200);

    const results = (await response.json()) as Array<{ id: string; username: string }>;
    expect(results.length).toBe(20);
    expect(results.every((row) => row.username.startsWith('member'))).toBe(true);
    expect(results.some((row) => row.id === SEEKER)).toBe(false);
  });

  it('returns an empty list for an unknown prefix', async () => {
    const response = await search('zzzz');
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual([]);
  });
});
