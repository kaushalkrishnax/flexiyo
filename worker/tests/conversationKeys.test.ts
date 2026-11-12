import { SELF } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  countRows,
  db,
  resetDatabase,
  seedConversation,
  seedConversationKeyDevice,
  seedConversationKeyEpoch,
  seedDevice,
  seedUser,
  tokenFor,
} from './support.js';

const ALICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const BOB = 'bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb';
const CONVERSATION = 'c0c0c0c0-c0c0-4c0c-8c0c-c0c0c0c0c0c0';
const IDENTITY = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const EPHEMERAL = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const NONCE = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const CIPHERTEXT = 'YWJj';
const TAG = 'AAAAAAAAAAAAAAAAAAAAAA==';

let aliceDevice = 0;
let bobDevice = 0;

async function api(
  method: string,
  path: string,
  options: {
    userId?: string;
    installation?: string;
    body?: unknown;
  } = {},
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
  aliceDevice = await seedConversationKeyDevice(ALICE, 'v2-alice', IDENTITY);
  bobDevice = await seedConversationKeyDevice(BOB, 'v2-bob', IDENTITY);
  await seedConversation(CONVERSATION, ALICE, BOB);
  await seedConversationKeyEpoch(
    CONVERSATION,
    1,
    aliceDevice,
    [aliceDevice, bobDevice],
  );
});

describe('conversation-key v2 messages', () => {
  it('persists one ciphertext and no per-device delivery rows', async () => {
    const id = crypto.randomUUID();
    const response = await api(
      'POST',
      `/api/conversations/${CONVERSATION}/messages`,
      {
        installation: 'v2-alice',
        body: {
          encryptionVersion: 2,
          id,
          recipientId: BOB,
          ciphertext: CIPHERTEXT,
          nonce: NONCE,
          authTag: TAG,
          keyEpoch: 1,
        },
      },
    );

    expect(response.status).toBe(201);
    const body = await response.json() as Record<string, unknown>;
    expect(body).toMatchObject({
      id,
      conversationId: CONVERSATION,
      encryptionVersion: 2,
      ciphertext: CIPHERTEXT,
      nonce: NONCE,
      authTag: TAG,
      keyEpoch: 1,
    });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(1);
    expect(await countRows('SELECT COUNT(*) AS n FROM message_deliveries')).toBe(0);

    const stored = await db.prepare(
      'SELECT encryption_version, ciphertext, nonce, auth_tag, key_epoch FROM messages WHERE id = ?',
    ).bind(id).first<Record<string, unknown>>();
    expect(stored).toEqual({
      encryption_version: 2,
      ciphertext: CIPHERTEXT,
      nonce: NONCE,
      auth_tag: TAG,
      key_epoch: 1,
    });
  });

  it('rejects a send while device revocation requires key rotation', async () => {
    await db.prepare(
      'UPDATE conversations SET key_rotation_required = 1 WHERE id = ?',
    ).bind(CONVERSATION).run();

    const response = await api(
      'POST',
      `/api/conversations/${CONVERSATION}/messages`,
      {
        installation: 'v2-alice',
        body: {
          encryptionVersion: 2,
          id: crypto.randomUUID(),
          recipientId: BOB,
          ciphertext: CIPHERTEXT,
          nonce: NONCE,
          authTag: TAG,
          keyEpoch: 1,
        },
      },
    );
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: 'key_rotation_required' });
    expect(await countRows('SELECT COUNT(*) AS n FROM messages')).toBe(0);
  });

  it('rejects a stale encryption epoch', async () => {
    const response = await api(
      'POST',
      `/api/conversations/${CONVERSATION}/messages`,
      {
        installation: 'v2-alice',
        body: {
          encryptionVersion: 2,
          id: crypto.randomUUID(),
          recipientId: BOB,
          ciphertext: CIPHERTEXT,
          nonce: NONCE,
          authTag: TAG,
          keyEpoch: 2,
        },
      },
    );
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({
      error: 'key_epoch_conflict',
      currentEpoch: 1,
    });
  });
});

describe('conversation-key device bootstrap and QR pairing', () => {
  it('allows first-device bootstrap and requires pairing for another installation', async () => {
    await resetDatabase();
    await seedUser(ALICE);

    const first = await api('POST', '/api/devices/v2/register', {
      body: { installationId: 'first-v2', identityPublicKey: IDENTITY },
    });
    expect(first.status).toBe(201);
    expect(await first.json()).toMatchObject({ status: 'active', encryptionVersion: 2 });

    const second = await api('POST', '/api/devices/v2/register', {
      body: { installationId: 'second-v2', identityPublicKey: IDENTITY },
    });
    expect(second.status).toBe(409);
    expect(await second.json()).toMatchObject({ error: 'pairing_required' });
  });

  it('creates, joins and approves a QR pairing session', async () => {
    const create = await api(
      'POST',
      '/api/devices/pairing/create',
      {
        installation: 'v2-alice',
        body: { initiatorEphemeralPublic: EPHEMERAL },
      },
    );
    expect(create.status).toBe(201);
    const created = await create.json() as { sessionId: string };

    const joined = await api(
      'POST',
      `/api/devices/pairing/${created.sessionId}/join`,
      {
        body: {
          installationId: 'joined-installation',
          identityPublicKey: IDENTITY,
          joinedEphemeralPublic: EPHEMERAL,
          nonce: NONCE,
          ciphertext: CIPHERTEXT,
          mac: TAG,
        },
      },
    );
    expect(joined.status).toBe(200);

    const approve = await api(
      'POST',
      `/api/devices/pairing/${created.sessionId}/approve`,
      { installation: 'v2-alice', body: {} },
    );
    expect(approve.status).toBe(200);
    const approved = await approve.json() as { deviceId: number };
    expect(approved.deviceId).toBeGreaterThan(0);

    const session = await api('GET', `/api/devices/pairing/${created.sessionId}`);
    expect(await session.json()).toMatchObject({
      status: 'approved',
      deviceId: approved.deviceId,
    });
    expect(await countRows(
      `SELECT COUNT(*) AS n FROM devices
       WHERE user_id = ? AND installation_id = 'joined-installation'
         AND encryption_version = 2 AND status = 'active'`,
      ALICE,
    )).toBe(1);
  });
});


// ---------------------------------------------------------------------------
// POST /key-envelopes
// ---------------------------------------------------------------------------
describe('POST /key-envelopes: epoch_not_found', () => {
  it('returns 404 when posting envelopes for a non-existent epoch', async () => {
    // Epoch 999 was never created
    const response = await api(
      'POST',
      `/api/conversations/${CONVERSATION}/key-envelopes`,
      {
        installation: 'v2-alice',
        body: {
          epoch: 999,
          envelopes: [
            {
              recipientDeviceId: aliceDevice,
              ephemeralPublicKey: IDENTITY,
              nonce: NONCE,
              ciphertext: CIPHERTEXT,
              mac: TAG,
            },
          ],
        },
      },
    );
    expect(response.status).toBe(409);
  });
});

describe('POST /key-envelopes: idempotency', () => {
  it('returns added:1 on first call and added:0 on duplicate', async () => {
    const payload = {
      epoch: 1,
      envelopes: [
        {
          recipientDeviceId: aliceDevice,
          ephemeralPublicKey: IDENTITY,
          nonce: NONCE,
          ciphertext: CIPHERTEXT,
          mac: TAG,
        },
      ],
    };

    const first = await api(
      'POST',
      `/api/conversations/${CONVERSATION}/key-envelopes`,
      { installation: 'v2-alice', body: payload },
    );
    expect(first.status).toBe(200);
    const firstBody = await first.json() as { added: number };
    expect(firstBody.added).toBe(1);

    const second = await api(
      'POST',
      `/api/conversations/${CONVERSATION}/key-envelopes`,
      { installation: 'v2-alice', body: payload },
    );
    expect(second.status).toBe(200);
    const secondBody = await second.json() as { added: number };
    expect(secondBody.added).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// POST /key-epochs
// ---------------------------------------------------------------------------
describe('POST /key-epochs: stale epoch rejected', () => {
  it('returns 409 epoch_conflict when proposed epoch skips ahead', async () => {
    // Current epoch is 1, so only epoch 2 is valid; submitting 5 must fail.
    const response = await api(
      'POST',
      `/api/conversations/${CONVERSATION}/key-epochs`,
      {
        installation: 'v2-alice',
        body: {
          epoch: 5,
          envelopes: [
            {
              recipientDeviceId: aliceDevice,
              ephemeralPublicKey: IDENTITY,
              nonce: NONCE,
              ciphertext: CIPHERTEXT,
              mac: TAG,
            },
            {
              recipientDeviceId: bobDevice,
              ephemeralPublicKey: IDENTITY,
              nonce: NONCE,
              ciphertext: CIPHERTEXT,
              mac: TAG,
            },
          ],
        },
      },
    );
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: 'epoch_conflict' });
  });
});

describe('POST /key-epochs: missing device envelope rejected', () => {
  it('returns 409 missing_device_envelopes when a device has no envelope', async () => {
    // Only supply alice's envelope; bob's device is missing.
    const response = await api(
      'POST',
      `/api/conversations/${CONVERSATION}/key-epochs`,
      {
        installation: 'v2-alice',
        body: {
          epoch: 2,
          envelopes: [
            {
              recipientDeviceId: aliceDevice,
              ephemeralPublicKey: IDENTITY,
              nonce: NONCE,
              ciphertext: CIPHERTEXT,
              mac: TAG,
            },
          ],
        },
      },
    );
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: 'missing_device_envelopes' });
  });
});

describe('POST /key-epochs: v1 device rejected', () => {
  it('returns 403 when a v1 (non-upgraded) device attempts to create an epoch', async () => {
    // Seed a v1 device for alice (no encryption_version = 2)
    await seedDevice(ALICE, 'v1-alice');

    const response = await api(
      'POST',
      `/api/conversations/${CONVERSATION}/key-epochs`,
      {
        // No X-Installation-Id header → resolveRequestDevice returns null/v1 device
        installation: 'v1-alice',
        body: {
          epoch: 2,
          envelopes: [
            {
              recipientDeviceId: aliceDevice,
              ephemeralPublicKey: IDENTITY,
              nonce: NONCE,
              ciphertext: CIPHERTEXT,
              mac: TAG,
            },
            {
              recipientDeviceId: bobDevice,
              ephemeralPublicKey: IDENTITY,
              nonce: NONCE,
              ciphertext: CIPHERTEXT,
              mac: TAG,
            },
          ],
        },
      },
    );
    expect(response.status).toBe(403);
  });
});
