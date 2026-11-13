import type { DeviceStatus, Env, DeviceRow } from '../types.js';

export const INSTALLATION_HEADER = 'X-Installation-Id';

export async function resolveRequestDevice(
  request: Request,
  env: Env,
  userId: string,
): Promise<DeviceRow | null> {
  const installationId = request.headers.get(INSTALLATION_HEADER);
  if (!installationId) return null;
  const device = await env.DB.prepare(
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
  const placeholders = statuses.map(() => '?').join(', ');
  const rows = await env.DB.prepare(
    `SELECT id FROM devices WHERE user_id = ? AND status IN (${placeholders}) ORDER BY id`,
  )
    .bind(userId, ...statuses)
    .all<{ id: number }>();
  return rows.results.map((r) => r.id);
}
