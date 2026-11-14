import type { DeviceStatus, Env, DeviceRow } from '../types.js';
import { getSqlDb } from '../database/turso.js';

export const INSTALLATION_HEADER = 'X-Installation-Id';

export async function resolveRequestDevice(
  request: Request,
  env: Env,
  userId: string,
): Promise<DeviceRow | null> {
  const installationId = request.headers.get(INSTALLATION_HEADER);
  if (!installationId) return null;
  const db = getSqlDb(env, request);
  const device = await db.prepare(
    `SELECT * FROM devices WHERE user_id = ? AND installation_id = ?`,
  )
    .bind(userId, installationId)
    .first<DeviceRow>();
  return device ?? null;
}

export function isActiveV2Device(
  device: DeviceRow | null,
): device is DeviceRow & { identity_public_key: string } {
  return Boolean(
    device && device.status === 'active' && device.identity_public_key,
  );
}

export async function deviceIdsFor(
  env: Env,
  userId: string,
  statuses: DeviceStatus[],
): Promise<number[]> {
  const db = getSqlDb(env);
  const placeholders = statuses.map(() => '?').join(', ');
  const rows = await db.prepare(
    `SELECT id FROM devices WHERE user_id = ? AND status IN (${placeholders}) ORDER BY id`,
  )
    .bind(userId, ...statuses)
    .all<{ id: number }>();
  return rows.results.map((r) => r.id);
}
