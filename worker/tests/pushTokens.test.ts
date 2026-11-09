import { SELF } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  countRows,
  resetDatabase,
  seedUser,
  tokenFor,
} from './support.js';

const ALICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const BOB = 'bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb';

async function register(userId: string, token: string): Promise<Response> {
  return SELF.fetch(
    new Request('https://example.com/api/push/register', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${await tokenFor(userId)}`,
      },
      body: JSON.stringify({ token, platform: 'android' }),
    }),
  );
}

beforeEach(async () => {
  await resetDatabase();
  await seedUser(ALICE);
  await seedUser(BOB);
});

describe('push token registration cap', () => {
  it('accepts ten tokens and rejects the eleventh', async () => {
    for (let i = 0; i < 10; i += 1) {
      const response = await register(ALICE, `token-${i}`);
      expect(response.status).toBe(200);
    }

    const rejected = await register(ALICE, 'token-10');

    expect(rejected.status).toBe(409);
    expect(await rejected.json()).toMatchObject({
      error: 'push_token_limit_reached',
      limit: 10,
    });
    expect(
      await countRows('SELECT COUNT(*) AS n FROM push_tokens WHERE user_id = ?', ALICE),
    ).toBe(10);
  });

  it('re-registering an owned token at the cap is idempotent', async () => {
    for (let i = 0; i < 10; i += 1) {
      await register(ALICE, `token-${i}`);
    }

    const response = await register(ALICE, 'token-0');

    expect(response.status).toBe(200);
    expect(
      await countRows('SELECT COUNT(*) AS n FROM push_tokens WHERE user_id = ?', ALICE),
    ).toBe(10);
  });

  it('allows another account to claim a token without spending its own quota twice', async () => {
    await register(ALICE, 'shared-token');
    for (let i = 0; i < 9; i += 1) {
      await register(BOB, `bob-token-${i}`);
    }

    const response = await register(BOB, 'shared-token');

    expect(response.status).toBe(200);
    expect(
      await countRows('SELECT COUNT(*) AS n FROM push_tokens WHERE user_id = ?', BOB),
    ).toBe(10);
    expect(
      await countRows(
        "SELECT COUNT(*) AS n FROM push_tokens WHERE token = 'shared-token' AND user_id = ?",
        BOB,
      ),
    ).toBe(1);
  });
});
