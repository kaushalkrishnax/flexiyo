import { IRequest, Router } from 'itty-router';
import { z } from 'zod';
import type { AuthenticatedRequest, DeviceStatus, Env, PairingSessionRow } from '../types.js';
import { authMiddleware } from '../middleware/auth.js';
import { resolveRequestDevice } from '../middleware/device.js';
import { validateKeyEnvelope, validatePublicKey } from '../services/conversationKeys.js';
import { generateId } from '../utils/crypto.js';
import { readJsonBody } from '../utils/http.js';
import { MAX_ACTIVE_DEVICES } from './devices.js';

export const pairingRouter = Router({ base: '/api/devices/pairing' });

const createSchema = z.object({
  initiatorEphemeralPublic: z.string().min(1).max(128),
});
const joinSchema = z.object({
  installationId: z.string().min(1).max(128),
  identityPublicKey: z.string().min(1).max(128),
  joinedEphemeralPublic: z.string().min(1).max(128),
  nonce: z.string().min(1).max(128),
  ciphertext: z.string().min(1).max(4096),
  mac: z.string().min(1).max(128),
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

pairingRouter.post(
  '/create',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const device = await resolveRequestDevice(request, env, userId);
    if (!device || device.status !== 'active' || device.encryption_version !== 2) {
      return json({ error: 'An active conversation-key device is required' }, 403);
    }

    const bodyResult = await readJsonBody(request);
    if (!bodyResult.ok) return bodyResult.response;
    const parsed = createSchema.safeParse(bodyResult.body);
    if (!parsed.success || !validatePublicKey(parsed.data?.initiatorEphemeralPublic)) {
      return json({ error: 'Invalid pairing public key' }, 400);
    }

    const now = Math.floor(Date.now() / 1000);
    const id = generateId();
    const expiresAt = now + 180;
    await env.DB.prepare(
      `INSERT INTO pairing_sessions
         (id, user_id, initiator_device_id, initiator_ephemeral_public,
          status, created_at, expires_at)
       VALUES (?, ?, ?, ?, 'pending', ?, ?)`,
    ).bind(id, userId, device.id, parsed.data.initiatorEphemeralPublic, now, expiresAt).run();

    return json({
      sessionId: id,
      initiatorEphemeralPublic: parsed.data.initiatorEphemeralPublic,
      expiresAt,
    }, 201);
  },
);

pairingRouter.post(
  '/:id/join',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const { id } = request.params as { id: string };
    const bodyResult = await readJsonBody(request);
    if (!bodyResult.ok) return bodyResult.response;
    const parsed = joinSchema.safeParse(bodyResult.body);
    if (!parsed.success) {
      return json({ error: 'Validation failed', details: parsed.error.flatten() }, 400);
    }

    const value = parsed.data;
    if (!validatePublicKey(value.identityPublicKey) ||
        !validatePublicKey(value.joinedEphemeralPublic) ||
        validateKeyEnvelope({
          ephemeralPublicKey: value.joinedEphemeralPublic,
          nonce: value.nonce,
          ciphertext: value.ciphertext,
          mac: value.mac,
        })) {
      return json({ error: 'Invalid encrypted pairing payload' }, 400);
    }

    const session = await env.DB.prepare(
      `SELECT * FROM pairing_sessions
       WHERE id = ? AND user_id = ? AND status = 'pending' AND expires_at > ?`,
    ).bind(id, userId, Math.floor(Date.now() / 1000)).first<PairingSessionRow>();
    if (!session) return json({ error: 'Pairing session not found or expired' }, 404);

    const existing = await env.DB.prepare(
      `SELECT id, status, encryption_version FROM devices
       WHERE user_id = ? AND installation_id = ?`,
    ).bind(userId, value.installationId).first<{
      id: number;
      status: DeviceStatus;
      encryption_version: number;
    }>();
    // A legacy (v1) row for this installation may be upgraded in place by the
    // approval step; an already-linked v2 installation cannot pair again.
    if (existing && existing.encryption_version === 2) {
      return json({ error: 'Installation is already registered' }, 409);
    }

    const updated = await env.DB.prepare(
      `UPDATE pairing_sessions
       SET status = 'joined', joined_installation_id = ?, joined_identity_public = ?,
           joined_ephemeral_public = ?, joined_nonce = ?, joined_ciphertext = ?, joined_mac = ?
       WHERE id = ? AND user_id = ? AND status = 'pending' AND expires_at > ?`,
    ).bind(
      value.installationId,
      value.identityPublicKey,
      value.joinedEphemeralPublic,
      value.nonce,
      value.ciphertext,
      value.mac,
      id,
      userId,
      Math.floor(Date.now() / 1000),
    ).run();

    if ((updated.meta.changes ?? 0) === 0) {
      return json({ error: 'Pairing session was already used or expired' }, 409);
    }
    return json({ joined: true, sessionId: id });
  },
);

pairingRouter.get(
  '/:id',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const { id } = request.params as { id: string };
    const now = Math.floor(Date.now() / 1000);
    const session = await env.DB.prepare(
      'SELECT * FROM pairing_sessions WHERE id = ? AND user_id = ?',
    ).bind(id, userId).first<PairingSessionRow>();
    if (!session) return json({ error: 'Pairing session not found' }, 404);

    if (session.status !== 'approved' && session.status !== 'cancelled' && session.expires_at <= now) {
      await env.DB.prepare(
        `UPDATE pairing_sessions SET status = 'expired'
         WHERE id = ? AND status IN ('pending', 'joined') AND expires_at <= ?`,
      ).bind(id, now).run();
      return json({ sessionId: id, status: 'expired' });
    }

    return json({
      sessionId: id,
      status: session.status,
      expiresAt: session.expires_at,
      joinedInstallationId: session.joined_installation_id,
      joinedIdentityPublic: session.joined_identity_public,
      joinedEphemeralPublic: session.joined_ephemeral_public,
      joinedNonce: session.joined_nonce,
      joinedCiphertext: session.joined_ciphertext,
      joinedMac: session.joined_mac,
      deviceId: session.approved_device_id,
    });
  },
);

pairingRouter.post(
  '/:id/approve',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const { id } = request.params as { id: string };
    const initiator = await resolveRequestDevice(request, env, userId);
    if (!initiator || initiator.status !== 'active' || initiator.encryption_version !== 2) {
      return json({ error: 'An active conversation-key device is required' }, 403);
    }

    const now = Math.floor(Date.now() / 1000);
    const session = await env.DB.prepare(
      `SELECT * FROM pairing_sessions WHERE id = ? AND user_id = ?`,
    ).bind(id, userId).first<PairingSessionRow>();
    if (!session || session.initiator_device_id !== initiator.id || session.expires_at <= now) {
      return json({ error: 'Pairing session not found or expired' }, 404);
    }
    if (session.status === 'approved') {
      return json({ error: 'Pairing session already approved' }, 409);
    }
    if (session.status !== 'joined') {
      return json({ error: 'Pairing session is not awaiting approval' }, 409);
    }
    if (!session.joined_installation_id || !session.joined_identity_public) {
      return json({ error: 'Pairing payload is incomplete' }, 409);
    }

    const joinedInstallation = session.joined_installation_id;
    const existing = await env.DB.prepare(
      `SELECT id, status, encryption_version FROM devices
       WHERE user_id = ? AND installation_id = ?`,
    ).bind(userId, joinedInstallation).first<{
      id: number;
      status: DeviceStatus;
      encryption_version: number;
    }>();

    if (existing?.encryption_version === 2) {
      return json({ error: 'Installation is already registered' }, 409);
    }

    // A legacy installation may already own a v1 device row. Promote that row
    // instead of inserting a duplicate so its device id keeps resolving.
    const deviceStatement = existing
      ? env.DB.prepare(
          `UPDATE devices
           SET encryption_version = 2, identity_public_key = ?, status = 'active',
               revoked_at = NULL, last_seen_at = ?
           WHERE id = ? AND user_id = ? AND encryption_version = 1
             AND (? IN ('active', 'pending')
                  OR (SELECT COUNT(*) FROM devices
                      WHERE user_id = ? AND status IN ('active', 'pending')) < ?)
           RETURNING id`,
        ).bind(
          session.joined_identity_public,
          now,
          existing.id,
          userId,
          existing.status,
          userId,
          MAX_ACTIVE_DEVICES,
        )
      : env.DB.prepare(
          `INSERT INTO devices
             (user_id, installation_id, registration_id, identity_key,
              signed_pre_key_id, signed_pre_key_public, signed_pre_key_signature,
              status, created_at, last_seen_at, encryption_version, identity_public_key)
           SELECT ?, ?, 1, 'conversation-key-v2', 1, 'conversation-key-v2',
                  'conversation-key-v2', 'active', ?, ?, 2, ?
           WHERE EXISTS (
             SELECT 1 FROM pairing_sessions
             WHERE id = ? AND user_id = ? AND status = 'joined' AND expires_at > ?
           )
           AND (SELECT COUNT(*) FROM devices
                WHERE user_id = ? AND status IN ('active', 'pending')) < ?
           RETURNING id`,
        ).bind(
          userId,
          joinedInstallation,
          now,
          now,
          session.joined_identity_public,
          id,
          userId,
          now,
          userId,
          MAX_ACTIVE_DEVICES,
        );

    const results = await env.DB.batch([
      deviceStatement,
      env.DB.prepare(
        `UPDATE pairing_sessions
         SET status = 'approved',
             approved_device_id = (
               SELECT id FROM devices WHERE user_id = ? AND installation_id = ?
                 AND encryption_version = 2
             ),
             approved_at = ?
         WHERE id = ? AND user_id = ? AND status = 'joined' AND expires_at > ?`,
      ).bind(userId, joinedInstallation, now, id, userId, now),
    ]);

    const approvedDevice = results[0].results?.[0] as { id?: number } | undefined;
    if (!approvedDevice?.id || (results[1].meta.changes ?? 0) !== 1) {
      return json({ error: 'Device limit reached or pairing already completed' }, 409);
    }

    return json({ approved: true, deviceId: approvedDevice.id }, 200);
  },
);

pairingRouter.post(
  '/:id/cancel',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const { id } = request.params as { id: string };
    const device = await resolveRequestDevice(request, env, userId);
    if (!device || device.status !== 'active' || device.encryption_version !== 2) {
      return json({ error: 'An active conversation-key device is required' }, 403);
    }
    const result = await env.DB.prepare(
      `UPDATE pairing_sessions SET status = 'cancelled'
       WHERE id = ? AND user_id = ? AND initiator_device_id = ?
         AND status IN ('pending', 'joined')`,
    ).bind(id, userId, device.id).run();
    if ((result.meta.changes ?? 0) === 0) return json({ error: 'Pairing session not found' }, 404);
    return json({ cancelled: true });
  },
);
