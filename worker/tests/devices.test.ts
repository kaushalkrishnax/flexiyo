import { SELF } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  countRows,
  db,
  resetDatabase,
  seedDevice,
  seedUser,
  tokenFor,
} from './support.js';
import { MAX_ACTIVE_DEVICES, MAX_STORED_PREKEYS } from '../src/routes/devices.js';

const ALICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

async function api(
  method: string,
  path: string,
  body?: unknown,
  installation?: string,
): Promise<Response> {
  const headers = new Headers({ 'Content-Type': 'application/json' });
  headers.set('Authorization', `Bearer ${await tokenFor(ALICE)}`);
  if (installation) headers.set('X-Installation-Id', installation);
  return SELF.fetch(
    new Request(`https://example.com${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    }),
  );
}

function registerBody(installationId: string, overrides: Record<string, unknown> = {}) {
  return {
    installationId,
    identityKey: 'identity-key',
    registrationId: 1,
    signedPreKey: { keyId: 1, publicKey: 'signed-pre-key', signature: 'signature' },
    preKeys: [{ keyId: 1, publicKey: 'one-time-pre-key' }],
    ...overrides,
  };
}

async function seedActiveDevices(count: number): Promise<void> {
  for (let i = 0; i < count; i += 1) {
    await seedDevice(ALICE, `install-${i}`, 'active');
  }
}

describe('device registration limits', () => {
  beforeEach(async () => {
    await resetDatabase();
    await seedUser(ALICE);
  });

  it('rejects a sixth device when five slots are used', async () => {
    await seedActiveDevices(MAX_ACTIVE_DEVICES);

    const response = await api('POST', '/api/devices/register', registerBody('install-new'));

    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: 'device_limit_reached' });
    expect(
      await countRows(
        "SELECT COUNT(*) AS n FROM devices WHERE user_id = ? AND status IN ('active', 'pending')",
        ALICE,
      ),
    ).toBe(MAX_ACTIVE_DEVICES);
  });

  it('cannot bypass the limit by re-registering a disabled installation', async () => {
    await seedActiveDevices(MAX_ACTIVE_DEVICES);
    const disabled = await seedDevice(ALICE, 'install-disabled', 'disabled');

    const response = await api(
      'POST',
      '/api/devices/register',
      registerBody('install-disabled'),
    );

    expect(response.status).toBe(409);
    const row = await db
      .prepare('SELECT status FROM devices WHERE id = ?')
      .bind(disabled)
      .first<{ status: string }>();
    expect(row?.status).toBe('disabled');
    expect(
      await countRows('SELECT COUNT(*) AS n FROM pre_keys WHERE device_id = ?', disabled),
    ).toBe(0);
  });

  it('reactivates a disabled installation when a slot is free', async () => {
    await seedActiveDevices(MAX_ACTIVE_DEVICES - 1);
    const disabled = await seedDevice(ALICE, 'install-disabled', 'disabled');

    const response = await api(
      'POST',
      '/api/devices/register',
      registerBody('install-disabled'),
    );

    expect(response.status).toBe(201);
    const created = (await response.json()) as { deviceId: number; status: string };
    expect(created.deviceId).toBe(disabled);
    expect(created.status).toBe('active');
    expect(
      await countRows('SELECT COUNT(*) AS n FROM pre_keys WHERE device_id = ?', disabled),
    ).toBe(1);
  });

  it('promotes a pending device even when the counted slots are full', async () => {
    await seedActiveDevices(MAX_ACTIVE_DEVICES - 1);
    const pending = await seedDevice(ALICE, 'install-pending', 'pending');

    const response = await api('POST', `/api/devices/${pending}/enable`);

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ deviceId: pending, status: 'active' });
  });

  it('keeps a disabled device disabled when every slot is used', async () => {
    await seedActiveDevices(MAX_ACTIVE_DEVICES);
    const disabled = await seedDevice(ALICE, 'install-disabled', 'disabled');

    const response = await api('POST', `/api/devices/${disabled}/enable`);

    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: 'device_limit_reached' });
  });

  it('rejects oversized key material', async () => {
    const response = await api(
      'POST',
      '/api/devices/register',
      registerBody('install-large', {
        preKeys: [{ keyId: 1, publicKey: 'x'.repeat(4097) }],
      }),
    );

    expect(response.status).toBe(400);
  });
});

describe('one-time pre-key inventory', () => {
  beforeEach(async () => {
    await resetDatabase();
    await seedUser(ALICE);
  });

  it('caps stored unconsumed pre-keys and accepts only the remaining capacity', async () => {
    const device = await seedDevice(ALICE, 'install-alice');

    const existing = Array.from({ length: MAX_STORED_PREKEYS - 1 }, (_, index) =>
      db
        .prepare(
          `INSERT INTO pre_keys (id, device_id, key_id, public_key, created_at)
           VALUES (?, ?, ?, 'pk', 0)`,
        )
        .bind(crypto.randomUUID(), device, index + 1),
    );
    for (let i = 0; i < existing.length; i += 100) {
      await db.batch(existing.slice(i, i + 100));
    }

    const response = await api(
      'POST',
      '/api/devices/prekeys/replenish',
      { preKeys: [
        { keyId: 9001, publicKey: 'a' },
        { keyId: 9002, publicKey: 'b' },
        { keyId: 9003, publicKey: 'c' },
      ] },
      'install-alice',
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ added: 1, remaining: MAX_STORED_PREKEYS });
  });

  it('rejects oversized pre-key material', async () => {
    await seedDevice(ALICE, 'install-alice');

    const response = await api(
      'POST',
      '/api/devices/prekeys/replenish',
      { preKeys: [{ keyId: 1, publicKey: 'x'.repeat(4097) }] },
      'install-alice',
    );

    expect(response.status).toBe(400);
  });
});
