import type { Env } from '../types.js';
import { getSqlDb } from '../database/turso.js';

const BREVO_API_BASE = 'https://api.brevo.com/v3';
const CODE_TTL_SECONDS = 10 * 60;
const MAX_ATTEMPTS = 5;
export const DAILY_EMAIL_LIMIT = 3;
const DAY_WINDOW_SECONDS = 24 * 60 * 60;

interface SendEmailArgs {
  env: Env;
  to: string;
  subject: string;
  html: string;
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

export async function sendEmail({ env, to, subject, html, text }: SendEmailArgs): Promise<boolean> {
  const apiKey = env.BREVO_API_KEY;
  if (!apiKey) {
    console.warn('[brevo] BREVO_API_KEY not configured — skipping send');
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
const HASH_CONTEXT = 'flexiyo-email-code:';

function generateVerificationCode(): string {
  const max = 10 ** CODE_DIGITS;
  const cutoff = Math.floor(0x1_0000_0000 / max) * max;
  const buffer = new Uint32Array(1);
  do {
    crypto.getRandomValues(buffer);
  } while (buffer[0] >= cutoff);
  return String(buffer[0] % max).padStart(CODE_DIGITS, '0');
}

async function hashCode(env: Env, code: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(env.JWT_SECRET),
    { name: 'HMAC', hash: HASH_ALGORITHM },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(`${HASH_CONTEXT}${code}`),
  );
  return Array.from(new Uint8Array(signature), (b) => b.toString(16).padStart(2, '0')).join('');
}

function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i += 1) {
    diff |= left.charCodeAt(i) ^ right.charCodeAt(i);
  }
  return diff === 0;
}

export async function issueEmailVerificationCode(
  env: Env,
  userId: string,
  email: string,
): Promise<{ sent: boolean; capped?: boolean; code?: string }> {
  const db = getSqlDb(env);
  const code = generateVerificationCode();
  const now = Math.floor(Date.now() / 1000);
  const expiresAt = now + CODE_TTL_SECONDS;

  const upsert = await db.prepare(
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
      await hashCode(env, code),
      expiresAt,
      now,
      now,
      now,
      now, now,
      now,
    )
    .run();

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

  return { sent, code: sent ? undefined : code };
}

export async function verifyEmailCode(
  env: Env,
  userId: string,
  code: string,
): Promise<boolean> {
  const db = getSqlDb(env);
  const row = await db.prepare(
    `SELECT code_hash, email, expires_at, attempts
       FROM email_verification_codes
      WHERE user_id = ?
      LIMIT 1`,
  )
    .bind(userId)
    .first<EmailVerificationRow & { expires_at: number; attempts: number }>();

  if (!row || row.attempts >= MAX_ATTEMPTS || row.expires_at < Math.floor(Date.now() / 1000)) {
    if (row && row.attempts >= MAX_ATTEMPTS) {
      await db.prepare('DELETE FROM email_verification_codes WHERE user_id = ?')
        .bind(userId)
        .run();
    }
    return false;
  }

  const matches = constantTimeEqual(await hashCode(env, code), row.code_hash);

  if (matches) {
    await db.prepare('DELETE FROM email_verification_codes WHERE user_id = ?')
      .bind(userId)
      .run();
    return true;
  }

  await db.prepare(
    'UPDATE email_verification_codes SET attempts = attempts + 1 WHERE user_id = ?',
  )
    .bind(userId)
    .run();
  return false;
}
