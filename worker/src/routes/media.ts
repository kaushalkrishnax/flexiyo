import { IRequest, Router } from 'itty-router';
import type { Env, AuthenticatedRequest, MediaDto, MediaRow, ViewPolicy } from '../types.js';
import { authMiddleware } from '../middleware/auth.js';
import { decideView, viewLimit } from '../services/mediaViews.js';
import { generateId } from '../utils/crypto.js';
import { getConversationForMember } from './conversations.js';
import { getSqlDb, type SqlDatabase } from '../database/turso.js';

export const mediaRouter = Router({ base: '/api' });

const DEFAULT_MAX_UPLOAD_BYTES = 25 * 1024 * 1024;

const UPLOAD_CAP_VAR = 'MEDIA_DAILY_UPLOAD_BYTES';
const DOWNLOAD_CAP_VAR = 'MEDIA_DAILY_DOWNLOAD_BYTES';
const MAX_UPLOAD_VAR = 'MEDIA_MAX_UPLOAD_BYTES';
const TTL_VAR = 'MEDIA_TTL_DAYS';

type MediaEnvVar =
  | 'MEDIA_TTL_DAYS'
  | 'MEDIA_DAILY_UPLOAD_BYTES'
  | 'MEDIA_DAILY_DOWNLOAD_BYTES'
  | 'MEDIA_MAX_UPLOAD_BYTES';

function envNum(env: Env, name: MediaEnvVar, fallback: number): number {
  const raw = env[name];
  if (raw == null) return fallback;
  const v = parseInt(raw, 10);
  return Number.isFinite(v) && v > 0 ? v : fallback;
}

async function readBoundedBody(request: Request, maxBytes: number): Promise<ArrayBuffer | null> {
  const declared = request.headers.get('content-length');
  if (declared != null) {
    const length = Number(declared);
    if (Number.isFinite(length) && length > maxBytes) return null;
  }
  if (!request.body) return null;
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel().catch(() => {});
        return null;
      }
      chunks.push(value);
    }
  } catch {
    return null;
  } finally {
    reader.releaseLock();
  }
  if (total === 0) return null;
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes.buffer as ArrayBuffer;
}

async function reserveDailyBytes(
  db: SqlDatabase,
  userId: string,
  day: string,
  column: 'bytes_up' | 'bytes_down',
  size: number,
  cap: number,
): Promise<boolean> {
  const result = await db.prepare(
    `INSERT INTO daily_usage (user_id, day, bytes_up, bytes_down)
     SELECT ?, ?, ?, ? WHERE ? <= ?
     ON CONFLICT(user_id, day) DO UPDATE SET
       ${column} = daily_usage.${column} + excluded.${column}
     WHERE daily_usage.${column} + excluded.${column} <= ?
     RETURNING ${column}`,
  )
    .bind(userId, day, column === 'bytes_up' ? size : 0, column === 'bytes_down' ? size : 0, size, cap, cap)
    .first<{ bytes_up?: number; bytes_down?: number }>();
  return result != null;
}

async function releaseDailyBytes(
  db: SqlDatabase,
  userId: string,
  day: string,
  column: 'bytes_up' | 'bytes_down',
  size: number,
): Promise<void> {
  await db.prepare(
    `UPDATE daily_usage SET ${column} = MAX(0, ${column} - ?) WHERE user_id = ? AND day = ?`,
  ).bind(size, userId, day).run();
}

function utcDayKey(): string {
  const d = new Date();
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
}

async function consume(env: Env, db: SqlDatabase, mediaId: string, r2Key: string): Promise<void> {
  try {
    await env.MEDIA.delete(r2Key);
    await db.prepare('UPDATE media SET consumed = 1 WHERE id = ?').bind(mediaId).run();
  } catch {
    const retryAt = Math.floor(Date.now() / 1000) + 3_600;
    await db.prepare(
      'UPDATE media SET consumed = 1, expires_at = ? WHERE id = ?',
    ).bind(retryAt, mediaId).run();
  }
}

async function releaseView(db: SqlDatabase, mediaId: string, userId: string): Promise<void> {
  try {
    await db.batch([
      db.prepare(
        `UPDATE media_views SET count = count - 1
         WHERE media_id = ? AND user_id = ? AND count > 1`,
      ).bind(mediaId, userId),
      db.prepare(
        `DELETE FROM media_views WHERE media_id = ? AND user_id = ? AND count <= 1`,
      ).bind(mediaId, userId),
    ]);
  } catch {
    // Cleanup is best-effort; the media is consumed below regardless.
  }
}

mediaRouter.post(
  '/media',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const db = getSqlDb(env, request as unknown as Request);

    const url = new URL(request.url);
    const conversationId = url.searchParams.get('conversationId');
    const kindRaw = (url.searchParams.get('kind') ?? 'image');
    const viewPolicyRaw = (url.searchParams.get('viewPolicy') ?? 'unlimited');
    const durationMsRaw = url.searchParams.get('durationMs');
    const plaintextMime = url.searchParams.get('mimeType');
    const kind: 'image' | 'voice' = kindRaw === 'voice' ? 'voice' : 'image';
    const viewPolicy: ViewPolicy =
      ['once', 'twice', 'unlimited'].includes(viewPolicyRaw)
        ? (viewPolicyRaw as ViewPolicy)
        : 'unlimited';
    const durationMs = durationMsRaw ? parseInt(durationMsRaw, 10) : null;

    if (!conversationId) {
      return new Response(JSON.stringify({ error: 'conversationId is required' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const conv = await getConversationForMember(conversationId, userId, db);
    if (!conv) {
      return new Response(JSON.stringify({ error: 'Conversation not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const maxUpload = envNum(env, MAX_UPLOAD_VAR, DEFAULT_MAX_UPLOAD_BYTES);
    const body = await readBoundedBody(request, maxUpload);
    if (!body) {
      return new Response(JSON.stringify({ error: 'File is empty or too large' }), {
        status: 413,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    const size = body.byteLength;

    const uploadCap = envNum(env, UPLOAD_CAP_VAR, 50 * 1024 * 1024);
    const today = utcDayKey();
    const reserved = await reserveDailyBytes(db, userId, today, 'bytes_up', size, uploadCap);
    if (!reserved) {
      return new Response(JSON.stringify({ error: 'Daily upload quota reached' }), {
        status: 429,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const id = generateId();
    const r2Key = `media/${id}`;
    const now = Math.floor(Date.now() / 1000);
    const ttlDays = envNum(env, TTL_VAR, 14);
    const expiresAt = now + ttlDays * 86400;
    const mimeType = plaintextMime && plaintextMime.length <= 100
      ? plaintextMime
      : 'application/octet-stream';

    try {
      await env.MEDIA.put(r2Key, body, {
        httpMetadata: { contentType: 'application/octet-stream' },
        customMetadata: {
          conversationId,
          senderId: userId,
          kind,
          viewPolicy,
          size: String(size),
        },
      });
    } catch (error) {
      console.error('R2 media put failed', error);
      await releaseDailyBytes(db, userId, today, 'bytes_up', size).catch(() => {});
      return new Response(JSON.stringify({ error: 'Storage upload failed' }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    try {
      await db.prepare(
        `INSERT INTO media
          (id, conversation_id, sender_id, kind, view_policy, size, mime_type,
           r2_key, duration_ms, created_at, expires_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
        .bind(id, conversationId, userId, kind, viewPolicy, size, mimeType, r2Key,
              durationMs ?? null, now, expiresAt)
        .run();
    } catch (error) {
      await Promise.allSettled([
        env.MEDIA.delete(r2Key),
        releaseDailyBytes(db, userId, today, 'bytes_up', size),
      ]);
      console.error('Media metadata insert failed', error);
      return new Response(JSON.stringify({ error: 'Storage upload failed' }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const dto: MediaDto = { id, kind, viewPolicy: viewPolicy, size, durationMs, createdAt: now };
    return new Response(JSON.stringify(dto), {
      status: 201,
      headers: { 'Content-Type': 'application/json' },
    });
  },
);

mediaRouter.get(
  '/media/:id',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const { id: mediaId } = request.params as { id: string };
    const db = getSqlDb(env, request as unknown as Request);

    const media = await db.prepare('SELECT * FROM media WHERE id = ?')
      .bind(mediaId)
      .first<MediaRow & { consumed: number }>();
    if (!media) {
      return new Response(JSON.stringify({ error: 'Media not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    if (media.consumed === 1) {
      return new Response(JSON.stringify({ error: 'Media has expired' }), {
        status: 410,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const conv = await getConversationForMember(media.conversation_id, userId, db);
    if (!conv) {
      return new Response(JSON.stringify({ error: 'Not a conversation participant' }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const now = Math.floor(Date.now() / 1000);
    const today = utcDayKey();
    const isSender = media.sender_id === userId;
    const limit = viewLimit(media.view_policy);

    const downloadCap = envNum(env, DOWNLOAD_CAP_VAR, 200 * 1024 * 1024);

    let object: R2Object | null;
    try {
      object = await env.MEDIA.get(media.r2_key);
    } catch {
      object = null;
    }
    if (!object) {
      await consume(env, db, mediaId, media.r2_key);
      return new Response(JSON.stringify({ error: 'Media object unavailable' }), {
        status: 410,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    let isFinalView = false;
    let viewsRemaining: number | null = null;
    let claimedView = false;
    if (!isSender && limit !== null) {
      const claimed = await db.prepare(
        `INSERT INTO media_views (media_id, user_id, count, updated_at)
         VALUES (?, ?, 1, ?)
         ON CONFLICT(media_id, user_id) DO UPDATE SET
           count = media_views.count + 1,
           updated_at = excluded.updated_at
         WHERE media_views.count < ?
         RETURNING count`,
      )
        .bind(mediaId, userId, now, limit)
        .first<{ count: number }>();

      if (!claimed) {
        await releaseDailyBytes(db, userId, today, 'bytes_down', media.size).catch(() => {});
        return new Response(JSON.stringify({ error: 'View limit reached' }), {
          status: 410,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      claimedView = true;
      const decision = decideView(media.view_policy, claimed.count - 1);
      isFinalView = decision.final;
      viewsRemaining = decision.remaining;
    }

    const reservedDownload = await reserveDailyBytes(
      db, userId, today, 'bytes_down', media.size, downloadCap,
    );
    if (!reservedDownload) {
      if (claimedView) await releaseView(db, mediaId, userId);
      return new Response(JSON.stringify({ error: 'Daily download quota reached' }), {
        status: 429,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const r2Body = object as R2ObjectBody;
    let payload: ArrayBuffer;
    try {
      payload = await r2Body.arrayBuffer();
    } catch {
      await releaseDailyBytes(db, userId, today, 'bytes_down', media.size).catch(() => {});
      if (claimedView) await releaseView(db, mediaId, userId);
      await consume(env, db, mediaId, media.r2_key);
      return new Response(JSON.stringify({ error: 'Media object unavailable' }), {
        status: 410,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    if (isFinalView) {
      await consume(env, db, mediaId, media.r2_key);
    }
    const headers: Record<string, string> = {
      'Content-Type': r2Body.httpMetadata?.contentType ?? 'application/octet-stream',
      'Content-Length': String(r2Body.size ?? 0),
      'Cache-Control': media.view_policy === 'unlimited'
        ? 'private, max-age=60'
        : 'private, no-store',
    };
    if (viewsRemaining !== null) {
      headers['X-Media-Views-Remaining'] = String(viewsRemaining);
    }
    return new Response(payload, { status: 200, headers });
  },
);

mediaRouter.delete(
  '/media/:id',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const { id: mediaId } = request.params as { id: string };
    const db = getSqlDb(env, request as unknown as Request);

    const media = await db.prepare(
      'SELECT id, conversation_id, r2_key, sender_id FROM media WHERE id = ?',
    )
      .bind(mediaId)
      .first<{ id: string; conversation_id: string; r2_key: string; sender_id: string }>();

    if (media) {
      if (media.sender_id !== userId) {
        return new Response(JSON.stringify({ error: 'Only the sender can purge media' }), {
          status: 403,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      await consume(env, db, media.id, media.r2_key);
      await db.prepare('DELETE FROM media_views WHERE media_id = ?')
        .bind(media.id)
        .run();
    }

    return new Response(JSON.stringify({ purged: true }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  },
);
