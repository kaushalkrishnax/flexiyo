import { IRequest, Router } from 'itty-router';
import type { Env, AuthenticatedRequest, DeviceRow } from '../types.js';
import { authMiddleware } from '../middleware/auth.js';
import { readJsonBody } from '../utils/http.js';
import { postChatRoomJson } from '../utils/durableObject.js';
import { validatePublicKey } from '../services/conversationKeys.js';
import { getSqlDb, type SqlDatabase } from '../database/turso.js';

export const devicesRouter = Router({ base: '/api/devices' });

export const MAX_ACTIVE_DEVICES = 5;

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
    identityPublicKey: d.identity_public_key,
    createdAt: d.created_at,
    lastSeenAt: d.last_seen_at,
    revokedAt: d.revoked_at,
    encryptionVersion: 2,
  };
}

devicesRouter.get(
  '/',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const db = getSqlDb(env, request as unknown as Request);
    const rows = await db.prepare(
      `SELECT * FROM devices WHERE user_id = ? ORDER BY created_at ASC`,
    )
      .bind(userId)
      .all<DeviceRow>();
    return json({ devices: rows.results.map(deviceToJson) });
  },
);

devicesRouter.post(
  '/v2/register',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const db = getSqlDb(env, request as unknown as Request);
    const bodyResult = await readJsonBody(request);
    if (!bodyResult.ok) return bodyResult.response;
    const body = bodyResult.body as Record<string, unknown>;
    const installationId = body.installationId;
    const identityPublicKey = validatePublicKey(body.identityPublicKey);
    if (
      typeof installationId !== 'string' ||
      installationId.length < 1 ||
      installationId.length > 128 ||
      !identityPublicKey
    ) {
      return json({ error: 'Invalid installation or identity key' }, 400);
    }

    const existing = await db.prepare(
      `SELECT id, status, identity_public_key
       FROM devices WHERE user_id = ? AND installation_id = ?`,
    )
      .bind(userId, installationId)
      .first<Pick<DeviceRow, 'id' | 'status' | 'identity_public_key'>>();
    if (existing) {
      if (existing.status === 'active' && existing.identity_public_key === identityPublicKey) {
        return json({ deviceId: existing.id, status: existing.status, encryptionVersion: 2 });
      }
      return json({ error: 'installation_already_registered' }, 409);
    }

    const now = Math.floor(Date.now() / 1000);
    const inserted = await db.prepare(
      `INSERT INTO devices
         (user_id, installation_id, status, created_at, last_seen_at, identity_public_key)
       SELECT ?, ?, 'active', ?, ?, ?
       WHERE NOT EXISTS (
         SELECT 1 FROM devices WHERE user_id = ? AND status = 'active'
       )
       RETURNING id`,
    )
      .bind(userId, installationId, now, now, identityPublicKey, userId)
      .first<{ id: number }>();

    if (!inserted) {
      return json(
        {
          error: 'pairing_required',
          message: 'An existing active device must approve this installation.',
        },
        409,
      );
    }
    return json({ deviceId: inserted.id, status: 'active', encryptionVersion: 2 }, 201);
  },
);

devicesRouter.get(
  '/identity-keys/:userId',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const requesterId = (request as unknown as AuthenticatedRequest).user.sub;
    const { userId } = request.params as { userId: string };
    const db = getSqlDb(env, request as unknown as Request);
    const blocked = await db.prepare(
      `SELECT 1 FROM user_blocks
       WHERE (blocker_id = ? AND blocked_id = ?)
          OR (blocker_id = ? AND blocked_id = ?) LIMIT 1`,
    )
      .bind(userId, requesterId, requesterId, userId)
      .first();
    if (blocked) return json({ error: 'Cannot retrieve device keys for this account' }, 403);

    const rows = await db.prepare(
      `SELECT id, installation_id, identity_public_key
       FROM devices
       WHERE user_id = ? AND status = 'active' AND identity_public_key IS NOT NULL
       ORDER BY id`,
    )
      .bind(userId)
      .all<{
        id: number;
        installation_id: string;
        identity_public_key: string;
      }>();
    return json({
      userId,
      devices: (rows.results ?? []).map((row) => ({
        deviceId: row.id,
        installationId: row.installation_id,
        identityPublicKey: row.identity_public_key,
      })),
    });
  },
);

async function closeRevokedDeviceSockets(
  env: Env,
  db: SqlDatabase,
  userId: string,
  deviceId: number,
): Promise<void> {
  const [rooms] = await db.batch([
    db.prepare(`SELECT id FROM conversations WHERE user_a_id = ? OR user_b_id = ?`).bind(
      userId,
      userId,
    ),
    db.prepare(
      `UPDATE conversations SET key_rotation_required = 1
       WHERE key_epoch > 0 AND id IN (
         SELECT conversation_id FROM device_key_envelopes WHERE recipient_device_id = ?
       )`,
    ).bind(deviceId),
    db.prepare('DELETE FROM device_key_envelopes WHERE recipient_device_id = ?').bind(deviceId),
  ]);

  await Promise.all(
    ((rooms.results ?? []) as Array<{ id: string }>).map(({ id }) =>
      postChatRoomJson(env, id, '/disconnect-device', { userId, deviceId }),
    ),
  );
}

async function findOwnDevice(
  db: SqlDatabase,
  userId: string,
  rawId: string,
): Promise<DeviceRow | null> {
  const deviceId = Number.parseInt(rawId, 10);
  if (!Number.isInteger(deviceId)) return null;
  const device = await db.prepare(
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
    const db = getSqlDb(env, request as unknown as Request);

    const device = await findOwnDevice(db, userId, id);
    if (!device) return json({ error: 'Device not found' }, 404);
    if (device.status === 'disabled') return json(deviceToJson(device));

    await closeRevokedDeviceSockets(env, db, userId, device.id);
    await db.prepare(
      `UPDATE devices SET status = 'disabled', last_seen_at = ? WHERE id = ?`,
    )
      .bind(Math.floor(Date.now() / 1000), device.id)
      .run();

    const updated = await findOwnDevice(db, userId, id);
    return json(deviceToJson(updated!));
  },
);

devicesRouter.post(
  '/:id/enable',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const { id } = request.params as { id: string };
    const db = getSqlDb(env, request as unknown as Request);

    const device = await findOwnDevice(db, userId, id);
    if (!device) return json({ error: 'Device not found' }, 404);

    const result = await db.prepare(
      `UPDATE devices
       SET status = 'active', revoked_at = NULL, last_seen_at = ?
       WHERE id = ? AND user_id = ? AND status <> 'active'
         AND (status = 'pending'
              OR (
                SELECT COUNT(*) FROM devices
                WHERE user_id = ? AND status IN ('active', 'pending')
              ) < ?)`,
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

    const updated = await findOwnDevice(db, userId, id);
    return json(deviceToJson(updated!));
  },
);

devicesRouter.delete(
  '/:id',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const { id } = request.params as { id: string };
    const db = getSqlDb(env, request as unknown as Request);

    const device = await findOwnDevice(db, userId, id);
    if (!device) return json({ error: 'Device not found' }, 404);

    await closeRevokedDeviceSockets(env, db, userId, device.id);
    await db.prepare(`DELETE FROM devices WHERE id = ? AND user_id = ?`)
      .bind(device.id, userId)
      .run();

    return json({ revoked: true, deviceId: device.id });
  },
);
