import { IRequest, Router } from 'itty-router';
import { z } from 'zod';
import type { Env, AuthenticatedRequest, DeviceRow, PreKeyRow } from '../types.js';
import { authMiddleware } from '../middleware/auth.js';
import { generateId } from '../utils/crypto.js';

export const devicesRouter = Router({ base: '/api/devices' });

const preKeySchema = z.object({
  keyId: z.number().int().positive(),
  publicKey: z.string().min(1),
});

const registerDeviceSchema = z.object({
  deviceId: z.string().min(1).max(128),
  identityKey: z.string().min(1),
  registrationId: z.number().int().positive(),
  signedPreKey: z.object({
    keyId: z.number().int().positive(),
    publicKey: z.string().min(1),
    signature: z.string().min(1),
  }),
  preKeys: z.array(preKeySchema).min(1).max(200),
});

const replenishPreKeysSchema = z.object({
  preKeys: z.array(preKeySchema).min(1).max(200),
});

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
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const parsed = registerDeviceSchema.safeParse(body);
    if (!parsed.success) {
      return new Response(
        JSON.stringify({ error: 'Validation failed', details: parsed.error.flatten() }),
        { status: 400, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const { deviceId, identityKey, registrationId, signedPreKey, preKeys } = parsed.data;
    const deviceRowId = generateId();
    const now = Math.floor(Date.now() / 1000);

    // Upsert device (one device per user_id + device_id pair)
    await env.DB.prepare(
      `INSERT INTO devices
         (id, user_id, device_id, registration_id, identity_key,
          signed_pre_key_id, signed_pre_key_public, signed_pre_key_signature, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(user_id, device_id) DO UPDATE SET
         registration_id         = excluded.registration_id,
         identity_key            = excluded.identity_key,
         signed_pre_key_id       = excluded.signed_pre_key_id,
         signed_pre_key_public   = excluded.signed_pre_key_public,
         signed_pre_key_signature = excluded.signed_pre_key_signature`,
    )
      .bind(
        deviceRowId,
        userId,
        deviceId,
        registrationId,
        identityKey,
        signedPreKey.keyId,
        signedPreKey.publicKey,
        signedPreKey.signature,
        now,
      )
      .run();

    // Remove existing unused prekeys for this user (full reset on re-register)
    await env.DB.prepare('DELETE FROM pre_keys WHERE user_id = ? AND used = 0')
      .bind(userId)
      .run();

    // Insert new prekeys
    const preKeyInserts = preKeys.map((pk) =>
      env.DB.prepare(
        `INSERT OR IGNORE INTO pre_keys (id, user_id, key_id, public_key, created_at)
         VALUES (?, ?, ?, ?, ?)`,
      ).bind(generateId(), userId, pk.keyId, pk.publicKey, now),
    );

    // D1 batch insert
    await env.DB.batch(preKeyInserts);

    return new Response(
      JSON.stringify({ registered: true, preKeysStored: preKeys.length }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  },
);

devicesRouter.get(
  '/:userId/key-bundle',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const { userId } = request.params as { userId: string };

    // Fetch device (identity + signed prekey)
    const device = await env.DB.prepare(
      `SELECT * FROM devices WHERE user_id = ? LIMIT 1`,
    )
      .bind(userId)
      .first<DeviceRow>();

    if (!device) {
      return new Response(
        JSON.stringify({ error: 'No device registered for this user' }),
        { status: 404, headers: { 'Content-Type': 'application/json' } },
      );
    }

    // Consume one prekey (FIFO — oldest by created_at)
    const preKey = await env.DB.prepare(
      `SELECT * FROM pre_keys
       WHERE user_id = ? AND used = 0
       ORDER BY created_at ASC
       LIMIT 1`,
    )
      .bind(userId)
      .first<PreKeyRow>();

    if (!preKey) {
      return new Response(
        JSON.stringify({
          error: 'No prekeys available for this user. Ask them to replenish.',
        }),
        { status: 503, headers: { 'Content-Type': 'application/json' } },
      );
    }

    // Mark as used
    await env.DB.prepare('UPDATE pre_keys SET used = 1 WHERE id = ?')
      .bind(preKey.id)
      .run();

    return new Response(
      JSON.stringify({
        userId,
        deviceId: device.device_id,
        registrationId: device.registration_id,
        identityKey: device.identity_key,
        signedPreKey: {
          keyId: device.signed_pre_key_id,
          publicKey: device.signed_pre_key_public,
          signature: device.signed_pre_key_signature,
        },
        preKey: {
          keyId: preKey.key_id,
          publicKey: preKey.public_key,
        },
      }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  },
);

devicesRouter.get(
  '/prekeys/count',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;

    const result = await env.DB.prepare(
      'SELECT COUNT(*) as count FROM pre_keys WHERE user_id = ? AND used = 0',
    )
      .bind(userId)
      .first<{ count: number }>();

    return new Response(
      JSON.stringify({ remaining: result?.count ?? 0 }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  },
);

devicesRouter.post(
  '/prekeys/replenish',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const parsed = replenishPreKeysSchema.safeParse(body);
    if (!parsed.success) {
      return new Response(
        JSON.stringify({ error: 'Validation failed', details: parsed.error.flatten() }),
        { status: 400, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const { preKeys } = parsed.data;
    const now = Math.floor(Date.now() / 1000);

    const stmts = preKeys.map((pk) =>
      env.DB.prepare(
        `INSERT OR IGNORE INTO pre_keys (id, user_id, key_id, public_key, created_at)
         VALUES (?, ?, ?, ?, ?)`,
      ).bind(generateId(), userId, pk.keyId, pk.publicKey, now),
    );

    await env.DB.batch(stmts);

    return new Response(
      JSON.stringify({ added: preKeys.length }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  },
);
