import { IRequest, Router } from 'itty-router';
import { z } from 'zod';
import type { AuthenticatedRequest, Env } from '../types.js';
import { authMiddleware } from '../middleware/auth.js';
import { isActiveV2Device, resolveRequestDevice } from '../middleware/device.js';
import { generateId } from '../utils/crypto.js';
import { readJsonBody } from '../utils/http.js';
import { getConversationForMember } from './conversations.js';
import { validateKeyEnvelope } from '../services/conversationKeys.js';
import { getSqlDb, type SqlDatabase } from '../database/turso.js';

export const keysRouter = Router({ base: '/api/conversations' });

const envelopeSchema = z.object({
  recipientDeviceId: z.number().int().positive(),
  ephemeralPublicKey: z.string().min(1).max(128),
  nonce: z.string().min(1).max(128),
  ciphertext: z.string().min(1).max(64 * 1024),
  mac: z.string().min(1).max(128),
});

const publishEpochSchema = z.object({
  epoch: z.number().int().positive(),
  envelopes: z.array(envelopeSchema).min(1).max(50),
});

const addEnvelopesSchema = z.object({
  epoch: z.number().int().positive(),
  envelopes: z.array(envelopeSchema).min(1).max(50),
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function parseEnvelopes(
  envelopes: z.infer<typeof envelopeSchema>[],
): { ok: true; rows: z.infer<typeof envelopeSchema>[] } | { ok: false; error: string } {
  const seen = new Set<number>();
  for (const envelope of envelopes) {
    if (seen.has(envelope.recipientDeviceId)) {
      return { ok: false, error: 'duplicate_recipient_device' };
    }
    seen.add(envelope.recipientDeviceId);
    const invalid = validateKeyEnvelope(envelope as unknown as Record<string, unknown>);
    if (invalid) return { ok: false, error: invalid };
  }
  return { ok: true, rows: envelopes };
}

async function activeDeviceIds(db: SqlDatabase, userIds: string[]): Promise<number[]> {
  const placeholders = userIds.map(() => '?').join(', ');
  const rows = await db.prepare(
    `SELECT id FROM devices
     WHERE user_id IN (${placeholders})
       AND status = 'active'
       AND identity_public_key IS NOT NULL
     ORDER BY id`,
  )
    .bind(...userIds)
    .all<{ id: number }>();
  return (rows.results ?? []).map((row) => row.id);
}

keysRouter.get(
  '/:id/key-epochs',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const { id } = request.params as { id: string };
    const db = getSqlDb(env, request as unknown as Request);
    const conversation = await getConversationForMember(id, userId, db);
    if (!conversation) return json({ error: 'Conversation not found' }, 404);

    const rows = await db.prepare(
      `SELECT epoch, created_by_device_id, created_at
       FROM conversation_key_epochs WHERE conversation_id = ? ORDER BY epoch ASC`,
    )
      .bind(id)
      .all<{ epoch: number; created_by_device_id: number | null; created_at: number }>();

    return json({
      conversationId: id,
      currentEpoch: conversation.key_epoch,
      keyRotationRequired: conversation.key_rotation_required === 1,
      epochs: rows.results ?? [],
    });
  },
);

keysRouter.post(
  '/:id/key-epochs',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const { id } = request.params as { id: string };
    const db = getSqlDb(env, request as unknown as Request);
    const conversation = await getConversationForMember(id, userId, db);
    if (!conversation) return json({ error: 'Conversation not found' }, 404);
    if (conversation.request_status === 'rejected') {
      return json({ error: 'Conversation is closed' }, 403);
    }

    const device = await resolveRequestDevice(request, env, userId);
    if (!isActiveV2Device(device)) {
      return json({ error: 'An active conversation-key device is required' }, 403);
    }

    const bodyResult = await readJsonBody(request);
    if (!bodyResult.ok) return bodyResult.response;
    const parsed = publishEpochSchema.safeParse(bodyResult.body);
    if (!parsed.success) {
      return json({ error: 'Validation failed', details: parsed.error.flatten() }, 400);
    }

    const parsedEnvelopes = parseEnvelopes(parsed.data.envelopes);
    if (!parsedEnvelopes.ok) return json({ error: parsedEnvelopes.error }, 400);

    if (parsed.data.epoch !== conversation.key_epoch + 1) {
      return json(
        {
          error: 'epoch_conflict',
          currentEpoch: conversation.key_epoch,
        },
        409,
      );
    }

    const peerId =
      conversation.user_a_id === userId ? conversation.user_b_id : conversation.user_a_id;
    const participantDeviceCounts = await db.prepare(
      `SELECT
         (SELECT COUNT(*) FROM devices
          WHERE user_id = ? AND status = 'active' AND identity_public_key IS NOT NULL) AS own_count,
         (SELECT COUNT(*) FROM devices
          WHERE user_id = ? AND status = 'active' AND identity_public_key IS NOT NULL) AS peer_count`,
    )
      .bind(userId, peerId)
      .first<{ own_count: number; peer_count: number }>();
    if (
      !participantDeviceCounts ||
      participantDeviceCounts.own_count < 1 ||
      participantDeviceCounts.peer_count < 1
    ) {
      return json({ error: 'both_participants_need_active_v2_devices' }, 409);
    }
    const allowed = new Set(await activeDeviceIds(db, [userId, peerId]));
    for (const envelope of parsedEnvelopes.rows) {
      if (!allowed.has(envelope.recipientDeviceId)) {
        return json({ error: 'unknown_device', deviceId: envelope.recipientDeviceId }, 400);
      }
    }
    const missing = [...allowed].filter(
      (deviceId) => !parsedEnvelopes.rows.some((row) => row.recipientDeviceId === deviceId),
    );
    if (missing.length > 0) {
      return json({ error: 'missing_device_envelopes', missingDeviceIds: missing }, 409);
    }

    const now = Math.floor(Date.now() / 1000);
    const statements = [
      db.prepare(
        `UPDATE conversations
         SET key_epoch = ?, key_rotation_required = 0
         WHERE id = ? AND key_epoch = ?`,
      ).bind(parsed.data.epoch, id, conversation.key_epoch),
      db.prepare(
        `INSERT INTO conversation_key_epochs
           (conversation_id, epoch, created_by_device_id, created_at)
         SELECT ?, ?, ?, ?
         WHERE EXISTS (
           SELECT 1 FROM conversations WHERE id = ? AND key_epoch = ?
         )`,
      ).bind(id, parsed.data.epoch, device.id, now, id, parsed.data.epoch),
      ...parsedEnvelopes.rows.map((envelope) =>
        db.prepare(
          `INSERT INTO device_key_envelopes
             (id, conversation_id, epoch, recipient_device_id, sender_device_id,
              ephemeral_public_key, nonce, ciphertext, mac, created_at)
           SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
           WHERE EXISTS (
             SELECT 1 FROM conversation_key_epochs
             WHERE conversation_id = ? AND epoch = ?
           )`,
        ).bind(
          generateId(),
          id,
          parsed.data.epoch,
          envelope.recipientDeviceId,
          device.id,
          envelope.ephemeralPublicKey,
          envelope.nonce,
          envelope.ciphertext,
          envelope.mac,
          now,
          id,
          parsed.data.epoch,
        ),
      ),
    ];

    try {
      const results = await db.batch(statements);
      if ((results[0].meta.changes ?? 0) !== 1) {
        const current = await db.prepare(
          'SELECT key_epoch FROM conversations WHERE id = ?',
        )
          .bind(id)
          .first<{ key_epoch: number }>();
        return json({ error: 'epoch_conflict', currentEpoch: current?.key_epoch ?? 0 }, 409);
      }
    } catch {
      const current = await db.prepare(
        'SELECT key_epoch FROM conversations WHERE id = ?',
      )
        .bind(id)
        .first<{ key_epoch: number }>();
      return json({ error: 'epoch_conflict', currentEpoch: current?.key_epoch ?? 0 }, 409);
    }

    return json(
      {
        conversationId: id,
        epoch: parsed.data.epoch,
        envelopes: parsedEnvelopes.rows.length,
      },
      201,
    );
  },
);

keysRouter.post(
  '/:id/key-envelopes',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const { id } = request.params as { id: string };
    const db = getSqlDb(env, request as unknown as Request);
    const conversation = await getConversationForMember(id, userId, db);
    if (!conversation) return json({ error: 'Conversation not found' }, 404);

    const device = await resolveRequestDevice(request, env, userId);
    if (!isActiveV2Device(device)) {
      return json({ error: 'An active conversation-key device is required' }, 403);
    }

    const bodyResult = await readJsonBody(request);
    if (!bodyResult.ok) return bodyResult.response;
    const parsed = addEnvelopesSchema.safeParse(bodyResult.body);
    if (!parsed.success) {
      return json({ error: 'Validation failed', details: parsed.error.flatten() }, 400);
    }
    const parsedEnvelopes = parseEnvelopes(parsed.data.envelopes);
    if (!parsedEnvelopes.ok) return json({ error: parsedEnvelopes.error }, 400);

    if (parsed.data.epoch > conversation.key_epoch || parsed.data.epoch <= 0) {
      return json({ error: 'unknown_epoch', currentEpoch: conversation.key_epoch }, 409);
    }

    const epochExists = await db.prepare(
      `SELECT 1 FROM conversation_key_epochs WHERE conversation_id = ? AND epoch = ?`,
    )
      .bind(id, parsed.data.epoch)
      .first<{ 1: number }>();
    if (!epochExists) return json({ error: 'epoch_not_found' }, 404);

    const allowedRows = await db.prepare(
      `SELECT id FROM devices
       WHERE user_id = ? AND status = 'active' AND identity_public_key IS NOT NULL`,
    )
      .bind(userId)
      .all<{ id: number }>();
    const allowed = new Set((allowedRows.results ?? []).map((row) => row.id));
    for (const envelope of parsedEnvelopes.rows) {
      if (!allowed.has(envelope.recipientDeviceId)) {
        return json({ error: 'unknown_device', deviceId: envelope.recipientDeviceId }, 400);
      }
    }

    const now = Math.floor(Date.now() / 1000);
    const results = await db.batch(
      parsedEnvelopes.rows.map((envelope) =>
        db.prepare(
          `INSERT INTO device_key_envelopes
             (id, conversation_id, epoch, recipient_device_id, sender_device_id,
              ephemeral_public_key, nonce, ciphertext, mac, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(conversation_id, epoch, recipient_device_id) DO UPDATE SET
             sender_device_id = excluded.sender_device_id,
             ephemeral_public_key = excluded.ephemeral_public_key,
             nonce = excluded.nonce,
             ciphertext = excluded.ciphertext,
             mac = excluded.mac,
             created_at = excluded.created_at
           WHERE device_key_envelopes.ephemeral_public_key <> excluded.ephemeral_public_key
              OR device_key_envelopes.nonce <> excluded.nonce
              OR device_key_envelopes.ciphertext <> excluded.ciphertext
              OR device_key_envelopes.mac <> excluded.mac`,
        ).bind(
          generateId(),
          id,
          parsed.data.epoch,
          envelope.recipientDeviceId,
          device.id,
          envelope.ephemeralPublicKey,
          envelope.nonce,
          envelope.ciphertext,
          envelope.mac,
          now,
        ),
      ),
    );
    const added = results.reduce((sum, result) => sum + (result.meta.changes ?? 0), 0);

    return json({ added });
  },
);

keysRouter.get(
  '/:id/key-envelopes',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const userId = (request as unknown as AuthenticatedRequest).user.sub;
    const { id } = request.params as { id: string };
    const db = getSqlDb(env, request as unknown as Request);
    const conversation = await getConversationForMember(id, userId, db);
    if (!conversation) return json({ error: 'Conversation not found' }, 404);

    const device = await resolveRequestDevice(request, env, userId);
    if (!isActiveV2Device(device)) {
      return json({ error: 'Device registration required' }, 403);
    }

    const epochRaw = new URL(request.url).searchParams.get('epoch');
    const epoch = epochRaw == null ? null : Number.parseInt(epochRaw, 10);
    const rows =
      epoch == null
        ? await db.prepare(
            `SELECT conversation_id, epoch, ephemeral_public_key, nonce, ciphertext, mac
             FROM device_key_envelopes
             WHERE conversation_id = ? AND recipient_device_id = ?
             ORDER BY epoch ASC`,
          )
            .bind(id, device.id)
            .all<Record<string, unknown>>()
        : await db.prepare(
            `SELECT conversation_id, epoch, ephemeral_public_key, nonce, ciphertext, mac
             FROM device_key_envelopes
             WHERE conversation_id = ? AND recipient_device_id = ? AND epoch = ?`,
          )
            .bind(id, device.id, Number.isInteger(epoch) ? epoch : -1)
            .all<Record<string, unknown>>();

    return json({
      conversationId: id,
      currentEpoch: conversation.key_epoch,
      envelopes: (rows.results ?? []).map((row) => ({
        conversationId: row.conversation_id,
        epoch: row.epoch,
        ephemeralPublicKey: row.ephemeral_public_key,
        nonce: row.nonce,
        ciphertext: row.ciphertext,
        mac: row.mac,
      })),
    });
  },
);
