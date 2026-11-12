import { SELF } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  db,
  resetDatabase,
  seedConversationKeyDevice,
  seedDevice,
  seedUser,
  tokenFor,
} from './support.js';

const ALICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const BOB   = 'bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb';
// 32-byte base64 (valid X25519 public key)
const PUB32 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
// 24-byte base64 (XChaCha20 nonce)
const NONCE24 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
// 16-byte base64 (Poly1305 MAC)
const MAC16 = 'AAAAAAAAAAAAAAAAAAAAAA==';
// small valid ciphertext
const CT = 'YWJj';

let aliceDeviceId = 0;

async function api(
  method: string,
  path: string,
  options: { userId?: string; installation?: string; body?: unknown } = {},
): Promise<Response> {
  const headers = new Headers({ 'Content-Type': 'application/json' });
  headers.set('Authorization', `Bearer ${await tokenFor(options.userId ?? ALICE)}`);
  if (options.installation) headers.set('X-Installation-Id', options.installation);
  return SELF.fetch(new Request(`https://example.com${path}`, {
    method,
    headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
  }));
}

beforeEach(async () => {
  await resetDatabase();
  await seedUser(ALICE);
  await seedUser(BOB);
  aliceDeviceId = await seedConversationKeyDevice(ALICE, 'v2-alice', PUB32);
});

// ---------------------------------------------------------------------------
// Happy path: create → join → approve
// ---------------------------------------------------------------------------
describe('pairing: full create → join → approve flow', () => {
  it('creates a session, joins it and approves it to register a new device', async () => {
    const create = await api('POST', '/api/devices/pairing/create', {
      installation: 'v2-alice',
      body: { initiatorEphemeralPublic: PUB32 },
    });
    expect(create.status).toBe(201);
    const { sessionId } = await create.json() as { sessionId: string };
    expect(typeof sessionId).toBe('string');

    const join = await api('POST', `/api/devices/pairing/${sessionId}/join`, {
      body: {
        installationId: 'v2-alice-new',
        identityPublicKey: PUB32,
        joinedEphemeralPublic: PUB32,
        nonce: NONCE24,
        ciphertext: CT,
        mac: MAC16,
      },
    });
    expect(join.status).toBe(200);
    expect(await join.json()).toMatchObject({ joined: true, sessionId });

    // The initiator must receive the joining installation id and identity so
    // it can rebuild the proof AAD and verify the device before approval.
    const pending = await api('GET', `/api/devices/pairing/${sessionId}`);
    expect(pending.status).toBe(200);
    expect(await pending.json()).toMatchObject({
      status: 'joined',
      joinedInstallationId: 'v2-alice-new',
      joinedIdentityPublic: PUB32,
      joinedEphemeralPublic: PUB32,
      joinedNonce: NONCE24,
      joinedCiphertext: CT,
      joinedMac: MAC16,
    });

    const approve = await api('POST', `/api/devices/pairing/${sessionId}/approve`, {
      installation: 'v2-alice',
      body: {},
    });
    expect(approve.status).toBe(200);
    const approved = await approve.json() as { deviceId: number };
    expect(approved.deviceId).toBeGreaterThan(0);

    const session = await api('GET', `/api/devices/pairing/${sessionId}`);
    const sessionBody = await session.json() as Record<string, unknown>;
    expect(sessionBody.status).toBe('approved');
    expect(sessionBody.deviceId).toBe(approved.deviceId);

    const row = await db.prepare(
      `SELECT status FROM devices WHERE user_id = ? AND installation_id = 'v2-alice-new'`,
    ).bind(ALICE).first<{ status: string }>();
    expect(row?.status).toBe('active');
  });
});

// ---------------------------------------------------------------------------
// Approve after expiry
// ---------------------------------------------------------------------------
describe('pairing: approve after expiry rejected', () => {
  it('returns 404 when the session has already expired', async () => {
    const create = await api('POST', '/api/devices/pairing/create', {
      installation: 'v2-alice',
      body: { initiatorEphemeralPublic: PUB32 },
    });
    expect(create.status).toBe(201);
    const { sessionId } = await create.json() as { sessionId: string };

    const join = await api('POST', `/api/devices/pairing/${sessionId}/join`, {
      body: {
        installationId: 'v2-alice-new',
        identityPublicKey: PUB32,
        joinedEphemeralPublic: PUB32,
        nonce: NONCE24,
        ciphertext: CT,
        mac: MAC16,
      },
    });
    expect(join.status).toBe(200);

    // Backdating expires_at causes the approve query to find no matching row.
    await db.prepare(
      `UPDATE pairing_sessions SET expires_at = 1 WHERE id = ?`,
    ).bind(sessionId).run();

    const approve = await api('POST', `/api/devices/pairing/${sessionId}/approve`, {
      installation: 'v2-alice',
      body: {},
    });
    expect(approve.status).toBe(404);
  });
});

// ---------------------------------------------------------------------------
// Double-approve rejected
// ---------------------------------------------------------------------------
describe('pairing: double-approve rejected', () => {
  it('returns 409 on a second approve call for the same session', async () => {
    const create = await api('POST', '/api/devices/pairing/create', {
      installation: 'v2-alice',
      body: { initiatorEphemeralPublic: PUB32 },
    });
    const { sessionId } = await create.json() as { sessionId: string };

    await api('POST', `/api/devices/pairing/${sessionId}/join`, {
      body: {
        installationId: 'v2-alice-new',
        identityPublicKey: PUB32,
        joinedEphemeralPublic: PUB32,
        nonce: NONCE24,
        ciphertext: CT,
        mac: MAC16,
      },
    });

    const first = await api('POST', `/api/devices/pairing/${sessionId}/approve`, {
      installation: 'v2-alice',
      body: {},
    });
    expect(first.status).toBe(200);

    const second = await api('POST', `/api/devices/pairing/${sessionId}/approve`, {
      installation: 'v2-alice',
      body: {},
    });
    expect(second.status).toBe(409);
  });
});

// ---------------------------------------------------------------------------
// Join with wrong user rejected
// ---------------------------------------------------------------------------
describe('pairing: join with wrong user rejected', () => {
  it('returns 404 when a different user tries to join', async () => {
    const create = await api('POST', '/api/devices/pairing/create', {
      installation: 'v2-alice',
      body: { initiatorEphemeralPublic: PUB32 },
    });
    const { sessionId } = await create.json() as { sessionId: string };

    // BOB attempts to join ALICE's session — the query requires user_id = userId
    const join = await api('POST', `/api/devices/pairing/${sessionId}/join`, {
      userId: BOB,
      body: {
        installationId: 'v2-bob-new',
        identityPublicKey: PUB32,
        joinedEphemeralPublic: PUB32,
        nonce: NONCE24,
        ciphertext: CT,
        mac: MAC16,
      },
    });
    expect(join.status).toBe(404);
  });
});

// ---------------------------------------------------------------------------
// Legacy installation promoted by pairing
// ---------------------------------------------------------------------------
describe('pairing: legacy installation', () => {
  it('promotes the existing v1 row instead of inserting a duplicate', async () => {
    const legacyId = await seedDevice(ALICE, 'legacy-installation');

    const create = await api('POST', '/api/devices/pairing/create', {
      installation: 'v2-alice',
      body: { initiatorEphemeralPublic: PUB32 },
    });
    const { sessionId } = await create.json() as { sessionId: string };

    const join = await api('POST', `/api/devices/pairing/${sessionId}/join`, {
      body: {
        installationId: 'legacy-installation',
        identityPublicKey: PUB32,
        joinedEphemeralPublic: PUB32,
        nonce: NONCE24,
        ciphertext: CT,
        mac: MAC16,
      },
    });
    expect(join.status).toBe(200);

    const approve = await api('POST', `/api/devices/pairing/${sessionId}/approve`, {
      installation: 'v2-alice',
      body: {},
    });
    expect(approve.status).toBe(200);
    expect(await approve.json()).toMatchObject({ approved: true, deviceId: legacyId });

    const rows = await db.prepare(
      `SELECT id, encryption_version, status FROM devices
       WHERE user_id = ? AND installation_id = 'legacy-installation'`,
    ).bind(ALICE).all<{ id: number; encryption_version: number; status: string }>();
    expect(rows.results).toHaveLength(1);
    expect(rows.results?.[0]).toMatchObject({
      id: legacyId,
      encryption_version: 2,
      status: 'active',
    });
  });

  it('rejects joining an installation that is already a v2 device', async () => {
    const create = await api('POST', '/api/devices/pairing/create', {
      installation: 'v2-alice',
      body: { initiatorEphemeralPublic: PUB32 },
    });
    const { sessionId } = await create.json() as { sessionId: string };

    const join = await api('POST', `/api/devices/pairing/${sessionId}/join`, {
      body: {
        installationId: 'v2-alice',
        identityPublicKey: PUB32,
        joinedEphemeralPublic: PUB32,
        nonce: NONCE24,
        ciphertext: CT,
        mac: MAC16,
      },
    });
    expect(join.status).toBe(409);
    expect(await join.json()).toMatchObject({ error: 'Installation is already registered' });
  });
});

// ---------------------------------------------------------------------------
// Approval authorization
// ---------------------------------------------------------------------------
describe('pairing: approval authorization', () => {
  it('rejects approval from a different v2 device of the same account', async () => {
    await seedConversationKeyDevice(ALICE, 'v2-alice-other', PUB32);

    const create = await api('POST', '/api/devices/pairing/create', {
      installation: 'v2-alice',
      body: { initiatorEphemeralPublic: PUB32 },
    });
    const { sessionId } = await create.json() as { sessionId: string };

    await api('POST', `/api/devices/pairing/${sessionId}/join`, {
      body: {
        installationId: 'new-installation',
        identityPublicKey: PUB32,
        joinedEphemeralPublic: PUB32,
        nonce: NONCE24,
        ciphertext: CT,
        mac: MAC16,
      },
    });

    const approve = await api('POST', `/api/devices/pairing/${sessionId}/approve`, {
      installation: 'v2-alice-other',
      body: {},
    });
    expect(approve.status).toBe(404);
  });

  it('requires an active v2 device to create a pairing session', async () => {
    const create = await api('POST', '/api/devices/pairing/create', {
      userId: BOB,
      installation: 'not-registered',
      body: { initiatorEphemeralPublic: PUB32 },
    });
    expect(create.status).toBe(403);
  });
});
