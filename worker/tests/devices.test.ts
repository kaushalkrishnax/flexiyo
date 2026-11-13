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
  seedUser,
  tokenFor,
} from './support.js';
import { MAX_ACTIVE_DEVICES } from '../src/routes/devices.js';

const ALICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const BOB = 'bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb';
const IDENTITY = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const OTHER_IDENTITY = 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=';

async function api(
  method: string,
  path: string,
  body?: unknown,
  options: { userId?: string; installation?: string } = {},
): Promise<Response> {
  const headers = new Headers({ 'Content-Type': 'application/json' });
  headers.set('Authorization', `Bearer ${await tokenFor(options.userId ?? ALICE)}`);
  if (options.installation) headers.set('X-Installation-Id', options.installation);
  return SELF.fetch(
    new Request(`https://example.com${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    }),
  );
}

async function seedActiveDevices(count: number): Promise<void> {
  for (let i = 0; i < count; i += 1) {
    await seedConversationKeyDevice(ALICE, `install-${i}`, IDENTITY, 'active');
  }
}

describe('v2 device registration and bootstrap', () => {
  beforeEach(async () => {
    await resetDatabase();
    await seedUser(ALICE);
    await seedUser(BOB);
  });

  it('bootstraps the first v2 device, is idempotent on matching key, and rejects mismatches', async () => {
    const created = await api('POST', '/api/devices/v2/register', {
      installationId: 'install-alice',
      identityPublicKey: IDENTITY,
    });
    expect(created.status).toBe(201);
    const createdBody = (await created.json()) as {
      deviceId: number;
      status: string;
      encryptionVersion: number;
    };
    expect(createdBody).toMatchObject({ status: 'active', encryptionVersion: 2 });

    const repeat = await api('POST', '/api/devices/v2/register', {
      installationId: 'install-alice',
      identityPublicKey: IDENTITY,
    });
    expect(repeat.status).toBe(200);
    expect(await repeat.json()).toMatchObject({
      deviceId: createdBody.deviceId,
      status: 'active',
      encryptionVersion: 2,
    });

    const mismatch = await api('POST', '/api/devices/v2/register', {
      installationId: 'install-alice',
      identityPublicKey: OTHER_IDENTITY,
    });
    expect(mismatch.status).toBe(409);
    expect(await mismatch.json()).toMatchObject({ error: 'installation_already_registered' });
  });

  it('requires pairing when registering a second installation', async () => {
    await seedConversationKeyDevice(ALICE, 'v2-alice', IDENTITY);

    const second = await api('POST', '/api/devices/v2/register', {
      installationId: 'install-extra',
      identityPublicKey: IDENTITY,
    });

    expect(second.status).toBe(409);
    expect(await second.json()).toMatchObject({ error: 'pairing_required' });
  });

  it('rejects invalid installation ids and identity keys', async () => {
    const badKey = await api('POST', '/api/devices/v2/register', {
      installationId: 'install-bad',
      identityPublicKey: 'not-valid-base64-key',
    });
    expect(badKey.status).toBe(400);

    const emptyInstall = await api('POST', '/api/devices/v2/register', {
      installationId: '',
      identityPublicKey: IDENTITY,
    });
    expect(emptyInstall.status).toBe(400);
  });

  it('lists account devices and identity keys for non-blocked peers', async () => {
    await seedConversationKeyDevice(ALICE, 'v2-alice-1', IDENTITY, 'active');
    await seedConversationKeyDevice(ALICE, 'v2-alice-disabled', OTHER_IDENTITY, 'disabled');

    const listRes = await api('GET', '/api/devices');
    expect(listRes.status).toBe(200);
    const listBody = (await listRes.json()) as {
      devices: Array<{ installationId: string; status: string; encryptionVersion: number }>;
    };
    expect(listBody.devices).toEqual([
      expect.objectContaining({ installationId: 'v2-alice-1', status: 'active', encryptionVersion: 2 }),
      expect.objectContaining({ installationId: 'v2-alice-disabled', status: 'disabled', encryptionVersion: 2 }),
    ]);

    const keysRes = await api('GET', `/api/devices/identity-keys/${ALICE}`, undefined, { userId: BOB });
    expect(keysRes.status).toBe(200);
    const keysBody = (await keysRes.json()) as { devices: Array<{ installationId: string }> };
    expect(keysBody.devices).toEqual([
      expect.objectContaining({ installationId: 'v2-alice-1' }),
    ]);

    await seedBlock(ALICE, BOB);
    const blockedRes = await api('GET', `/api/devices/identity-keys/${ALICE}`, undefined, { userId: BOB });
    expect(blockedRes.status).toBe(403);
  });
});

describe('device status transitions and revocation', () => {
  beforeEach(async () => {
    await resetDatabase();
    await seedUser(ALICE);
    await seedUser(BOB);
  });

  it('promotes a pending device even when counted slots match MAX_ACTIVE_DEVICES', async () => {
    await seedActiveDevices(MAX_ACTIVE_DEVICES - 1);
    const pending = await seedConversationKeyDevice(ALICE, 'install-pending', IDENTITY, 'pending');

    const response = await api('POST', `/api/devices/${pending}/enable`);

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ deviceId: pending, status: 'active' });
  });

  it('keeps a disabled device disabled when every slot is used', async () => {
    await seedActiveDevices(MAX_ACTIVE_DEVICES);
    const disabled = await seedConversationKeyDevice(ALICE, 'install-disabled', IDENTITY, 'disabled');

    const response = await api('POST', `/api/devices/${disabled}/enable`);

    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: 'device_limit_reached' });
  });

  it('reactivates a disabled device when a slot is available', async () => {
    await seedActiveDevices(MAX_ACTIVE_DEVICES - 1);
    const disabled = await seedConversationKeyDevice(ALICE, 'install-disabled', IDENTITY, 'disabled');

    const response = await api('POST', `/api/devices/${disabled}/enable`);

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ deviceId: disabled, status: 'active' });
  });

  it('revokes a device, deletes its envelopes, and marks conversations for key rotation', async () => {
    const aliceDevice = await seedConversationKeyDevice(ALICE, 'v2-alice', IDENTITY);
    const bobDevice = await seedConversationKeyDevice(BOB, 'v2-bob', IDENTITY);
    const convId = 'c0c0c0c0-c0c0-4c0c-8c0c-c0c0c0c0c0c0';
    await seedConversation(convId, ALICE, BOB);
    await seedConversationKeyEpoch(convId, 1, aliceDevice, [aliceDevice, bobDevice]);

    const response = await api('DELETE', `/api/devices/${aliceDevice}`);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ revoked: true, deviceId: aliceDevice });

    expect(await countRows('SELECT COUNT(*) AS n FROM devices WHERE id = ?', aliceDevice)).toBe(0);
    expect(
      await countRows('SELECT COUNT(*) AS n FROM device_key_envelopes WHERE recipient_device_id = ?', aliceDevice),
    ).toBe(0);
    const conv = await db
      .prepare('SELECT key_rotation_required FROM conversations WHERE id = ?')
      .bind(convId)
      .first<{ key_rotation_required: number }>();
    expect(conv?.key_rotation_required).toBe(1);
  });
});
