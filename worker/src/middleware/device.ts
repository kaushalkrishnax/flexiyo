import type { DeviceStatus, Env, DeviceRow } from '../types.js';

export const INSTALLATION_HEADER = 'X-Installation-Id';

/**
 * Resolves the calling device from the X-Installation-Id header.
 * Returns null when the installation header is missing or unknown.
 */
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

/**
 * Active device ids of two accounts, keyed by owner. One round trip for both
 * sides of a conversation: sender-device sync and recipient fan-out need them
 * together.
 */
export async function pairedActiveDeviceIds(
  db: D1Database,
  userId: string,
  peerId: string,
): Promise<{ own: number[]; peer: number[] }> {
  const rows = await db
    .prepare(
      `SELECT id, user_id FROM devices
       WHERE status = 'active' AND (user_id = ? OR user_id = ?)
       ORDER BY id`,
    )
    .bind(userId, peerId)
    .all<{ id: number; user_id: string }>();

  const own: number[] = [];
  const peer: number[] = [];
  for (const row of rows.results ?? []) {
    if (row.user_id === userId) own.push(row.id);
    else peer.push(row.id);
  }
  return { own, peer };
}

/** All device ids of an account in the given statuses. */
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
