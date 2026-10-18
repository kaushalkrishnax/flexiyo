import { IRequest, Router } from 'itty-router';
import type { Env, AuthenticatedRequest, MediaDto, MediaRow, ViewPolicy } from '../types.js';
import { authMiddleware } from '../middleware/auth.js';
import { decideView } from '../services/mediaViews.js';
import { generateId } from '../utils/crypto.js';
import { getConversationForMember } from './conversations.js';

// Media upload/fetch through authed Worker routes; R2 is server-side only and
// the Worker sees ciphertext (AES-256-GCM is applied client-side).
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

function utcDayKey(): string {
  const d = new Date();
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
}

/** Removes the stored object and leaves a consumed tombstone behind. */
async function consume(env: Env, mediaId: string, r2Key: string): Promise<void> {
  try {
    await env.MEDIA.delete(r2Key);
  } catch (_) {}
  await env.DB.prepare('UPDATE media SET consumed = 1 WHERE id = ?')
    .bind(mediaId)
    .run();
}

mediaRouter.post(
  '/media',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;

    const url = new URL(request.url);
    const conversationId = url.searchParams.get('conversationId');
    const kindRaw = (url.searchParams.get('kind') ?? 'image');
    const viewPolicyRaw = (url.searchParams.get('viewPolicy') ?? 'unlimited');
    const durationMsRaw = url.searchParams.get('durationMs');
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

    const conv = await getConversationForMember(conversationId, userId, env.DB);
    if (!conv) {
      return new Response(JSON.stringify({ error: 'Conversation not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const arrayBuffer = await request.arrayBuffer();
    const size = arrayBuffer.byteLength;
    const maxUpload = envNum(env, MAX_UPLOAD_VAR, DEFAULT_MAX_UPLOAD_BYTES);
    if (size === 0 || size > maxUpload) {
      return new Response(JSON.stringify({ error: 'File is empty or too large' }), {
        status: 413,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const uploadCap = envNum(env, UPLOAD_CAP_VAR, 50 * 1024 * 1024);
    const today = utcDayKey();
    const upRow = await env.DB.prepare(
      'SELECT bytes_up FROM daily_usage WHERE user_id = ? AND day = ?',
    )
      .bind(userId, today)
      .first<{ bytes_up: number }>();
    const currentUp = upRow?.bytes_up ?? 0;
    if (currentUp + size > uploadCap) {
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
    const mimeType = kind === 'voice' ? 'audio/mp4' : 'image/jpeg';

    try {
      await env.MEDIA.put(r2Key, arrayBuffer, {
        httpMetadata: { contentType: mimeType },
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
      return new Response(JSON.stringify({ error: 'Storage upload failed' }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    await env.DB.prepare(
      `INSERT INTO media
        (id, conversation_id, sender_id, kind, view_policy, size, mime_type,
         r2_key, duration_ms, created_at, expires_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
      .bind(id, conversationId, userId, kind, viewPolicy, size, mimeType, r2Key,
            durationMs ?? null, now, expiresAt)
      .run();

    await env.DB.prepare(
      `INSERT INTO daily_usage (user_id, day, bytes_up, bytes_down)
       VALUES (?, ?, ?, 0)
       ON CONFLICT(user_id, day) DO UPDATE SET bytes_up = bytes_up + excluded.bytes_up`,
    )
      .bind(userId, today, size)
      .run();

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

    const media = await env.DB.prepare('SELECT * FROM media WHERE id = ?')
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

    const conv = await getConversationForMember(media.conversation_id, userId, env.DB);
    if (!conv) {
      return new Response(JSON.stringify({ error: 'Not a conversation participant' }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const now = Math.floor(Date.now() / 1000);
    const today = utcDayKey();
    const isSender = media.sender_id === userId;

    // View-once / view-twice enforcement (non-sender).
    let isFinalView = false;
    let viewsRemaining: number | null = null;
    if (!isSender && media.view_policy !== 'unlimited') {
      const existing = await env.DB.prepare(
        'SELECT count FROM media_views WHERE media_id = ? AND user_id = ?',
      )
        .bind(mediaId, userId)
        .first<{ count: number }>();
      const decision = decideView(media.view_policy, existing?.count ?? 0);
      if (!decision.allowed) {
        await consume(env, mediaId, media.r2_key);
        return new Response(JSON.stringify({ error: 'View limit reached' }), {
          status: 410,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      await env.DB.prepare(
        `INSERT INTO media_views (media_id, user_id, count, updated_at)
         VALUES (?, ?, 1, ?)
         ON CONFLICT(media_id, user_id) DO UPDATE SET count = count + 1, updated_at = excluded.updated_at`,
      )
        .bind(mediaId, userId, now)
        .run();
      isFinalView = decision.final;
      viewsRemaining = decision.remaining;
    }

    const downloadCap = envNum(env, DOWNLOAD_CAP_VAR, 200 * 1024 * 1024);
    const downRow = await env.DB.prepare(
      'SELECT bytes_down FROM daily_usage WHERE user_id = ? AND day = ?',
    )
      .bind(userId, today)
      .first<{ bytes_down: number }>();
    const currentDown = downRow?.bytes_down ?? 0;
    if (currentDown + media.size > downloadCap) {
      return new Response(JSON.stringify({ error: 'Daily download quota reached' }), {
        status: 429,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    await env.DB.prepare(
      `INSERT INTO daily_usage (user_id, day, bytes_up, bytes_down)
       VALUES (?, ?, 0, ?)
       ON CONFLICT(user_id, day) DO UPDATE SET bytes_down = bytes_down + excluded.bytes_down`,
    )
      .bind(userId, today, media.size)
      .run();

    let object: R2Object | null;
    try {
      object = await env.MEDIA.get(media.r2_key);
    } catch {
      object = null;
    }
    if (!object) {
      await consume(env, mediaId, media.r2_key);
      return new Response(JSON.stringify({ error: 'Media object unavailable' }), {
        status: 410,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const r2Body = object as R2ObjectBody;
    const payload = await r2Body.arrayBuffer();
    if (isFinalView) {
      // Last allowed view served — purge the object now so nothing remains
      // in storage even if the app never fetches it again.
      await consume(env, mediaId, media.r2_key);
    }
    const headers: Record<string, string> = {
      'Content-Type': r2Body.httpMetadata?.contentType ?? 'application/octet-stream',
      'Content-Length': String(r2Body.size ?? 0),
      // Limited media must not be served from an HTTP cache: a cached body
      // would hand out extra views without the counter moving.
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

// Explicit purge so a client that has used up every allowed view (or unsends a
// message) can make the object disappear immediately instead of waiting for the
// TTL sweep. Members only; idempotent.
mediaRouter.delete(
  '/media/:id',
  (req: IRequest, env: Env) => authMiddleware(req as unknown as Request, env),
  async (request: IRequest, env: Env): Promise<Response> => {
    const authReq = request as unknown as AuthenticatedRequest;
    const userId = authReq.user.sub;
    const { id: mediaId } = request.params as { id: string };

    const media = await env.DB.prepare(
      'SELECT id, conversation_id, r2_key FROM media WHERE id = ?',
    )
      .bind(mediaId)
      .first<{ id: string; conversation_id: string; r2_key: string }>();

    if (media) {
      const conv = await getConversationForMember(
        media.conversation_id,
        userId,
        env.DB,
      );
      if (!conv) {
        return new Response(JSON.stringify({ error: 'Not a conversation participant' }), {
          status: 403,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      await consume(env, media.id, media.r2_key);
      await env.DB.prepare('DELETE FROM media_views WHERE media_id = ?')
        .bind(media.id)
        .run();
    }

    return new Response(JSON.stringify({ purged: true }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  },
);
