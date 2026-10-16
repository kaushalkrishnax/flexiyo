import { IRequest, Router } from 'itty-router';
import { z } from 'zod';
import type { Env, AuthenticatedRequest, DeviceRow, DeviceStatus } from '../types.js';
import { authMiddleware } from '../middleware/auth.js';
import { generateId } from '../utils/crypto.js';

export const devicesRouter = Router({ base: '/api/devices' });

/** Maximum number of devices in ('active','pending') per account. */
export const MAX_ACTIVE_DEVICES = 5;

const preKeySchema = z.object({
  keyId: z.number().int().positive(),
  publicKey: z.string().min(1),
});

const registerDeviceSchema = z.object({
  installationId: z.string().min(1).max(128),
  identityKey: z.string().min(1),
  registrationId: z.number().int().positive(),
  signedPreKey: z.object({
    keyId: z.number().int().positive(),
    publicKey: z.string().min(1),
    signature: z.string().min(1),
  }),
  preKeys: z.array(preKeySchema).min(1).max(200),
  activate: z.boolean().optional(),
});

const replenishPreKeysSchema = z.object({
  preKeys: z.array(preKeySchema).min(1).max(200),
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function deviceToJson(d: DeviceRow) {
  return {
    deviceId: d.id,
    installationId: d.installation_id,
    status: d.status,
    registrationId: d.registration_id,
    identityKey: d.identity_key,
    signedPreKeyId: d.signed_pre_key_id,
    createdAt: d.created_at,
    lastSeenAt: d.last_seen_at,
    revokedAt: d.revoked_at,
  };
}

devicesRouter.get(
  '/',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const rows = await env.DB.prepare(
      `SELECT * FROM devices WHERE user_id = ? ORDER BY created_at ASC`,
    )
      .bind(userId)
      .all<DeviceRow>();
    return json({ devices: rows.results.map(deviceToJson) });
  },
);

devicesRouter.post(
  '/register',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return json({ error: 'Invalid JSON body' }, 400);
    }

    const parsed = registerDeviceSchema.safeParse(body);
    if (!parsed.success) {
      return json({ error: 'Validation failed', details: parsed.error.flatten() }, 400);
    }

    const { installationId, identityKey, registrationId, signedPreKey, preKeys } = parsed.data;
    const status: DeviceStatus = parsed.data.activate === false ? 'pending' : 'active';
    const now = Math.floor(Date.now() / 1000);

    let deviceId: number;

    const existing = await env.DB.prepare(
      `SELECT * FROM devices WHERE user_id = ? AND installation_id = ?`,
    )
      .bind(userId, installationId)
      .first<DeviceRow>();

    if (existing) {
      // Safe reactivation of a known installation: refresh its keys and return
      // it to the requested status. No new device slot is consumed.
      await env.DB.prepare(
        `UPDATE devices
         SET registration_id = ?, identity_key = ?, signed_pre_key_id = ?,
             signed_pre_key_public = ?, signed_pre_key_signature = ?,
             status = ?, revoked_at = NULL, last_seen_at = ?
         WHERE id = ?`,
      )
        .bind(
          registrationId,
          identityKey,
          signedPreKey.keyId,
          signedPreKey.publicKey,
          signedPreKey.signature,
          status,
          now,
          existing.id,
        )
        .run();
      deviceId = existing.id;
    } else {
      // Single-statement conditional insert: atomic under D1 (which has no
      // multi-statement transactions) — racing registrations cannot exceed 5.
      const inserted = await env.DB.prepare(
        `INSERT INTO devices
           (user_id, installation_id, registration_id, identity_key,
            signed_pre_key_id, signed_pre_key_public, signed_pre_key_signature,
            status, created_at, last_seen_at)
         SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
         WHERE (
           SELECT COUNT(*) FROM devices
           WHERE user_id = ? AND status IN ('active', 'pending')
         ) < ?`,
      )
        .bind(
          userId,
          installationId,
          registrationId,
          identityKey,
          signedPreKey.keyId,
          signedPreKey.publicKey,
          signedPreKey.signature,
          status,
          now,
          now,
          userId,
          MAX_ACTIVE_DEVICES,
        )
        .run();

      if (inserted.meta.changes === 0) {
        return json(
          {
            error: 'device_limit_reached',
            message: `An account may have at most ${MAX_ACTIVE_DEVICES} active devices`,
            limit: MAX_ACTIVE_DEVICES,
          },
          409,
        );
      }
      deviceId = Number(inserted.meta.last_row_id);
    }

    // One-time pre-keys are PER DEVICE: reset only this installation's keys.
    // Sibling devices' key material is never touched by a re-registration.
    await env.DB.prepare(`DELETE FROM pre_keys WHERE device_id = ?`)
      .bind(deviceId)
      .run();

    const preKeyInserts = preKeys.map((pk) =>
      env.DB.prepare(
        `INSERT OR IGNORE INTO pre_keys (id, device_id, key_id, public_key, created_at)
         VALUES (?, ?, ?, ?, ?)`,
      ).bind(generateId(), deviceId, pk.keyId, pk.publicKey, now),
    );
    await env.DB.batch(preKeyInserts);

    return json({ deviceId, installationId, status }, 201);
  },
);

// ---------------------------------------------------------------------------
// Device lifecycle: disable / enable / revoke (owner-scoped by device id)
// ---------------------------------------------------------------------------

async function findOwnDevice(
  env: Env,
  userId: string,
  rawId: string,
): Promise<DeviceRow | null> {
  const deviceId = Number.parseInt(rawId, 10);
  if (!Number.isInteger(deviceId)) return null;
  const device = await env.DB.prepare(
    `SELECT * FROM devices WHERE id = ? AND user_id = ?`,
  )
    .bind(deviceId, userId)
    .first<DeviceRow>();
  return device ?? null;
}

devicesRouter.post(
  '/:id/disable',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const { id } = request.params as { id: string };

    const device = await findOwnDevice(env, userId, id);
    if (!device) return json({ error: 'Device not found' }, 404);
    if (device.status === 'disabled') return json(deviceToJson(device));

    // Disabled devices stop being served in key bundles immediately (pre-key
    // invalidation) and free their device-limit slot. Rows are retained for
    // auditability and can be re-enabled.
    await env.DB.prepare(
      `UPDATE devices SET status = 'disabled', last_seen_at = ? WHERE id = ?`,
    )
      .bind(Math.floor(Date.now() / 1000), device.id)
      .run();

    const updated = await findOwnDevice(env, userId, id);
    return json(deviceToJson(updated!));
  },
);

devicesRouter.post(
  '/:id/enable',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const { id } = request.params as { id: string };

    const device = await findOwnDevice(env, userId, id);
    if (!device) return json({ error: 'Device not found' }, 404);

    // Conditional update: slot check and status flip happen in ONE statement,
    // so concurrent enables cannot overshoot the limit.
    const result = await env.DB.prepare(
      `UPDATE devices
       SET status = 'active', revoked_at = NULL, last_seen_at = ?
       WHERE id = ? AND user_id = ? AND status <> 'active'
         AND (
           SELECT COUNT(*) FROM devices
           WHERE user_id = ? AND status IN ('active', 'pending')
         ) < ?`,
    )
      .bind(Math.floor(Date.now() / 1000), device.id, userId, userId, MAX_ACTIVE_DEVICES)
      .run();

    if (result.meta.changes === 0) {
      if (device.status === 'active') return json(deviceToJson(device));
      return json(
        {
          error: 'device_limit_reached',
          message: `An account may have at most ${MAX_ACTIVE_DEVICES} active devices`,
          limit: MAX_ACTIVE_DEVICES,
        },
        409,
      );
    }

    const updated = await findOwnDevice(env, userId, id);
    return json(deviceToJson(updated!));
  },
);

devicesRouter.delete(
  '/:id',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const { id } = request.params as { id: string };

    const device = await findOwnDevice(env, userId, id);
    if (!device) return json({ error: 'Device not found' }, 404);

    // Hard revocation: FK cascades remove this device's one-time pre-keys and
    // its recipient-side delivery rows; sender attribution on other devices'
    // delivery rows degrades to NULL (ON DELETE SET NULL) instead of deleting
    // their receipts.
    await env.DB.prepare(`DELETE FROM devices WHERE id = ? AND user_id = ?`)
      .bind(device.id, userId)
      .run();

    return json({ revoked: true, deviceId: device.id });
  },
);

// ---------------------------------------------------------------------------
// Key bundles
// ---------------------------------------------------------------------------

/**
 * Atomically claims the next unused one-time pre-key for a device.
 * Single conditional UPDATE ... RETURNING — two concurrent requests can never
 * receive the same key (D1 runs each statement in its own implicit transaction).
 */
async function claimOneTimePreKey(
  env: Env,
  deviceId: number,
  now: number,
): Promise<{ key_id: number; public_key: string } | null> {
  const claimed = await env.DB.prepare(
    `UPDATE pre_keys SET consumed_at = ?
     WHERE id = (
       SELECT id FROM pre_keys
       WHERE device_id = ? AND consumed_at IS NULL
       ORDER BY key_id ASC LIMIT 1
     )
     AND consumed_at IS NULL
     RETURNING key_id, public_key`,
  )
    .bind(now, deviceId)
    .first<{ key_id: number; public_key: string }>();
  return claimed ?? null;
}

function bundleToJson(
  device: DeviceRow,
  preKey: { key_id: number; public_key: string } | null,
) {
  return {
    deviceId: device.id,
    installationId: device.installation_id,
    registrationId: device.registration_id,
    identityKey: device.identity_key,
    signedPreKey: {
      keyId: device.signed_pre_key_id,
      publicKey: device.signed_pre_key_public,
      signature: device.signed_pre_key_signature,
    },
    // null = X3DH without a one-time pre-key (protocol-valid).
    preKey: preKey ? { keyId: preKey.key_id, publicKey: preKey.public_key } : null,
    messageType: 'prekey',
  };
}

/**
 * Multi-device bundle fetch: one bundle per ACTIVE device of the target
 * account, each with its own atomically consumed one-time pre-key.
 */
devicesRouter.get(
  '/key-bundles/:userId',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const { userId } = request.params as { userId: string };
    const now = Math.floor(Date.now() / 1000);

    const target = await env.DB.prepare(`SELECT id FROM users WHERE id = ?`)
      .bind(userId)
      .first<{ id: string }>();
    if (!target) return json({ error: 'User not found' }, 404);

    const devices = await env.DB.prepare(
      `SELECT * FROM devices WHERE user_id = ? AND status = 'active' ORDER BY id ASC`,
    )
      .bind(userId)
      .all<DeviceRow>();

    const bundles = [];
    for (const device of devices.results) {
      const preKey = await claimOneTimePreKey(env, device.id, now);
      bundles.push(bundleToJson(device, preKey));
    }

    return json({ userId, bundles });
  },
);

/**
 * Legacy single-bundle endpoint (pre-multi-device contract): the account's
 * oldest ACTIVE device with a freshly claimed one-time pre-key. Kept so
 * released clients keep working; new clients use /key-bundles/:userId.
 */
devicesRouter.get(
  '/key-bundle/:userId',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const { userId } = request.params as { userId: string };
    const now = Math.floor(Date.now() / 1000);

    const device = await env.DB.prepare(
      `SELECT * FROM devices WHERE user_id = ? AND status = 'active' ORDER BY id ASC LIMIT 1`,
    )
      .bind(userId)
      .first<DeviceRow>();
    if (!device) {
      return json({ error: 'No active device for this user' }, 404);
    }

    const preKey = await claimOneTimePreKey(env, device.id, now);
    if (!preKey) {
      return json(
        { error: 'No prekeys available for this user. Ask them to replenish.' },
        503,
      );
    }

    return json({
      userId,
      deviceId: device.id,
      registrationId: device.registration_id,
      identityKey: device.identity_key,
      signedPreKey: {
        keyId: device.signed_pre_key_id,
        publicKey: device.signed_pre_key_public,
        signature: device.signed_pre_key_signature,
      },
      preKey: { keyId: preKey.key_id, publicKey: preKey.public_key },
    });
  },
);

// ---------------------------------------------------------------------------
// One-time pre-key inventory (per device via X-Installation-Id header)
// ---------------------------------------------------------------------------

devicesRouter.get(
  '/prekeys/count',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const installationId = request.headers.get('X-Installation-Id');

    if (installationId) {
      const device = await env.DB.prepare(
        `SELECT id FROM devices WHERE user_id = ? AND installation_id = ?`,
      )
        .bind(userId, installationId)
        .first<{ id: number }>();
      const result = await env.DB.prepare(
        `SELECT COUNT(*) as count FROM pre_keys WHERE device_id = ? AND consumed_at IS NULL`,
      )
        .bind(device?.id ?? -1)
        .first<{ count: number }>();
      return json({ remaining: result?.count ?? 0 });
    }

    // Legacy / device-less callers: inventory across all serving devices.
    const result = await env.DB.prepare(
      `SELECT COUNT(*) as count FROM pre_keys pk
       JOIN devices d ON d.id = pk.device_id
       WHERE d.user_id = ? AND d.status = 'active' AND pk.consumed_at IS NULL`,
    )
      .bind(userId)
      .first<{ count: number }>();
    return json({ remaining: result?.count ?? 0 });
  },
);

devicesRouter.post(
  '/prekeys/replenish',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return json({ error: 'Invalid JSON body' }, 400);
    }

    const parsed = replenishPreKeysSchema.safeParse(body);
    if (!parsed.success) {
      return json({ error: 'Validation failed', details: parsed.error.flatten() }, 400);
    }

    const { preKeys } = parsed.data;
    const now = Math.floor(Date.now() / 1000);

    // Replenishment is always scoped to ONE device — either the caller's
    // installation (header) or, for legacy clients, the oldest active device.
    let device: { id: number } | null;
    const installationId = request.headers.get('X-Installation-Id');
    if (installationId) {
      device = await env.DB.prepare(
        `SELECT id FROM devices WHERE user_id = ? AND installation_id = ? AND status = 'active'`,
      )
        .bind(userId, installationId)
        .first<{ id: number }>();
      if (!device) {
        return json({ error: 'Unknown or inactive installation for this account' }, 404);
      }
    } else {
      device = await env.DB.prepare(
        `SELECT id FROM devices WHERE user_id = ? AND status = 'active' ORDER BY id ASC LIMIT 1`,
      )
        .bind(userId)
        .first<{ id: number }>();
      if (!device) {
        return json({ error: 'No active device to replenish' }, 404);
      }
    }

    const stmts = preKeys.map((pk) =>
      env.DB.prepare(
        `INSERT OR IGNORE INTO pre_keys (id, device_id, key_id, public_key, created_at)
         VALUES (?, ?, ?, ?, ?)`,
      ).bind(generateId(), device!.id, pk.keyId, pk.publicKey, now),
    );
    await env.DB.batch(stmts);

    const remaining = await env.DB.prepare(
      `SELECT COUNT(*) as count FROM pre_keys WHERE device_id = ? AND consumed_at IS NULL`,
    )
      .bind(device.id)
      .first<{ count: number }>();

    return json({ added: preKeys.length, deviceId: device.id, remaining: remaining?.count ?? 0 });
  },
);
