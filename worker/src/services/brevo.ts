import type { Env } from '../types.js';

/**
 * Brevo transactional email helpers.
 *
 * The Brevo API key lives ONLY in Worker secrets (`wrangler secret put
 * BREVO_API_KEY`) — never in the client bundle. Every call goes Worker →
 * Brevo directly over HTTPS; nothing secret crosses the client API surface.
 */

const BREVO_API_BASE = 'https://api.brevo.com/v3';
const CODE_TTL_SECONDS = 10 * 60; // verification codes expire after 10 minutes
const MAX_ATTEMPTS = 5; // per-code attempt ceiling
export const DAILY_EMAIL_LIMIT = 3; // verification emails per user per day
const DAY_WINDOW_SECONDS = 24 * 60 * 60;

interface SendEmailArgs {
  env: Env;
  to: string;
  subject: string;
  /** Rendered HTML body. */
  html: string;
  /** Plain-text fallback (some clients reject HTML-only mail). */
  text?: string;
}

interface EmailVerificationRow {
  id: string;
  user_id: string;
  code_hash: string;
  email: string;
  expires_at: number;
  attempts: number;
}

/** Send a transactional email through Brevo. Returns true on accepted send. */
export async function sendEmail({ env, to, subject, html, text }: SendEmailArgs): Promise<boolean> {
  const apiKey = env.BREVO_API_KEY;
  if (!apiKey) {
    // Dev/no-secret environments: don't fail the flow, just surface it.
    console.warn('[brevo] BREVO_API_KEY not configured — skipping send', { to, subject });
    return false;
  }

  try {
    const response = await fetch(`${BREVO_API_BASE}/smtp/email`, {
      method: 'POST',
      headers: {
        'accept': 'application/json',
        'api-key': apiKey,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        sender: {
          email: env.BREVO_SENDER_EMAIL || 'no-reply@flexiyo.app',
          name: env.BREVO_SENDER_NAME || 'Flexiyo',
        },
        to: [{ email: to }],
        subject,
        htmlContent: html,
        textContent: text ?? subject,
      }),
    });
    if (!response.ok) {
      console.error('[brevo] send failed', response.status, await response.text().catch(() => ''));
      return false;
    }
    return true;
  } catch (error) {
    console.error('[brevo] send error', error);
    return false;
  }
}

const CODE_DIGITS = 6;
const HASH_ALGORITHM = 'SHA-256';

async function hashCode(code: string): Promise<string> {
  const digest = await crypto.subtle.digest(HASH_ALGORITHM, new TextEncoder().encode(code));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Issue a verification code for a user: stores a hashed, expiring record in
 * `email_verification_codes` and emails the raw code via Brevo.
 * One active code per user — re-issuing overwrites the previous record.
 * Daily budget: at most {@link DAILY_EMAIL_LIMIT} emails per user per 24h,
 * enforced atomically inside the same upsert (no extra queries, no races).
 */
export async function issueEmailVerificationCode(
  env: Env,
  userId: string,
  email: string,
): Promise<{ sent: boolean; capped?: boolean; code?: string }> {
  const code = String(Math.floor(Math.random() * 10 ** CODE_DIGITS)).padStart(CODE_DIGITS, '0');
  const now = Math.floor(Date.now() / 1000);
  const expiresAt = now + CODE_TTL_SECONDS;

  // Rolling 24h window per user: if the stored window elapsed, the counter
  // restarts. The conditional update keeps concurrent requests honest — DB
  // arbitration means two parallel sends cannot both "fit" past the cap.
  const upsert = await env.DB.prepare(
    `INSERT INTO email_verification_codes
       (id, user_id, email, code_hash, expires_at, attempts, created_at,
        daily_count, window_started_at)
     VALUES (?, ?, ?, ?, ?, 0, ?, 1, ?)
     ON CONFLICT (user_id) DO UPDATE SET
       email = excluded.email,
       code_hash = excluded.code_hash,
       expires_at = excluded.expires_at,
       attempts = 0,
       created_at = excluded.created_at,
       daily_count = CASE
         WHEN email_verification_codes.window_started_at <= ? - ${DAY_WINDOW_SECONDS}
           THEN 1
         WHEN email_verification_codes.daily_count < ${DAILY_EMAIL_LIMIT}
           THEN email_verification_codes.daily_count + 1
         ELSE email_verification_codes.daily_count
       END,
       window_started_at = CASE
         WHEN email_verification_codes.window_started_at <= ? - ${DAY_WINDOW_SECONDS}
           THEN ?
         ELSE email_verification_codes.window_started_at
       END
     WHERE CASE
       WHEN email_verification_codes.window_started_at <= ? - ${DAY_WINDOW_SECONDS}
         THEN 1
       WHEN email_verification_codes.daily_count < ${DAILY_EMAIL_LIMIT}
         THEN 1
       ELSE 0
     END = 1`,
  )
    .bind(
      crypto.randomUUID(),
      userId,
      email,
      await hashCode(code),
      expiresAt,
      now,
      now, // INSERT window start
      now, now, now, // reset window
      now, // reset window (second CASE)
      now, now, // WHERE gate
    )
    .run();

  // meta.changes == 0 means the WHERE gate rejected the send → cap reached.
  if ((upsert.meta?.changes ?? 0) === 0) {
    return { sent: false, capped: true };
  }

  const sent = await sendEmail({
    env,
    to: email,
    subject: `Your Flexiyo verification code: ${code}`,
    text: `Your Flexiyo code is ${code}. It expires in ${CODE_TTL_SECONDS / 60} minutes.`,
    html: `<div style="font-family:sans-serif;max-width:480px">
      <h2>Verify your email</h2>
      <p>Your Flexiyo code is:</p>
      <p style="font-size:32px;font-weight:700;letter-spacing:6px;margin:12px 0">${code}</p>
      <p style="color:#666">This code expires in ${CODE_TTL_SECONDS / 60} minutes. If you didn't request it, ignore this email.</p>
    </div>`,
  });

  // Dev convenience: when no key is configured Surface the code in logs only.
  if (!sent) console.info('[brevo] dev verification code', { userId, code });
  return { sent, code: sent ? undefined : code };
}

/** Verify a submitted code for a user (crop: hashed match + TTL + attempts). */
export async function verifyEmailCode(
  env: Env,
  userId: string,
  code: string,
): Promise<boolean> {
  const row = await env.DB.prepare(
    `SELECT code_hash, email, expires_at, attempts
       FROM email_verification_codes
      WHERE user_id = ?
      LIMIT 1`,
  )
    .bind(userId)
    .first<EmailVerificationRow & { expires_at: number; attempts: number }>();

  if (!row || row.attempts >= MAX_ATTEMPTS || row.expires_at < Math.floor(Date.now() / 1000)) {
    if (row && row.attempts >= MAX_ATTEMPTS) {
      await env.DB.prepare('DELETE FROM email_verification_codes WHERE user_id = ?')
        .bind(userId)
        .run();
    }
    return false;
  }

  const matches = (await hashCode(code)) === row.code_hash;

  if (matches) {
    await env.DB.prepare('DELETE FROM email_verification_codes WHERE user_id = ?')
      .bind(userId)
      .run();
    return true;
  }

  await env.DB.prepare(
    'UPDATE email_verification_codes SET attempts = attempts + 1 WHERE user_id = ?',
  )
    .bind(userId)
    .run();
  return false;
}
