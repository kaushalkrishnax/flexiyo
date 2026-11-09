import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  DAILY_EMAIL_LIMIT,
  issueEmailVerificationCode,
  verifyEmailCode,
} from '../src/services/brevo.js';
import type { Env } from '../src/types.js';
import { db, resetDatabase, seedUser, testEnv } from './support.js';

const ALICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const EMAIL = 'alice@example.com';

function makeEnv(apiKey: string | undefined = 'test-brevo-key'): Env {
  return {
    DB: testEnv.DB,
    JWT_SECRET: testEnv.JWT_SECRET,
    BREVO_API_KEY: apiKey,
  } as unknown as Env;
}

interface VerificationRow {
  code_hash: string;
  expires_at: number;
  attempts: number;
  daily_count: number;
}

async function readRow(): Promise<VerificationRow | null> {
  return db
    .prepare(
      'SELECT code_hash, expires_at, attempts, daily_count FROM email_verification_codes WHERE user_id = ?',
    )
    .bind(ALICE)
    .first<VerificationRow>();
}

async function plainSha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

/** Intercepts Brevo sends and records the six-digit code from each subject. */
function stubBrevo(): { codes: string[]; fetchMock: ReturnType<typeof vi.fn> } {
  const codes: string[] = [];
  const fetchMock = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
    const payload = JSON.parse(String(init?.body ?? '{}')) as { subject?: string };
    const match = /(\d{6})/.exec(payload.subject ?? '');
    if (match) codes.push(match[1]);
    return new Response('{}', { status: 201 });
  });
  vi.stubGlobal('fetch', fetchMock);
  return { codes, fetchMock };
}

function wrongVariant(code: string): string {
  return `${code[0] === '0' ? '1' : '0'}${code.slice(1)}`;
}

beforeEach(async () => {
  await resetDatabase();
  await seedUser(ALICE);
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe('email verification codes', () => {
  it('stores a keyed hash, never the raw code or a plain digest', async () => {
    const { codes, fetchMock } = stubBrevo();
    const env = makeEnv();

    const result = await issueEmailVerificationCode(env, ALICE, EMAIL);

    expect(result.sent).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(codes).toHaveLength(1);
    expect(codes[0]).toMatch(/^\d{6}$/);

    const row = await readRow();
    expect(row).not.toBeNull();
    expect(row!.daily_count).toBe(1);
    expect(row!.code_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(row!.code_hash).not.toContain(codes[0]);
    expect(row!.code_hash).not.toBe(await plainSha256(codes[0]));
  });

  it('accepts the matching code once and consumes it', async () => {
    const { codes } = stubBrevo();
    const env = makeEnv();
    await issueEmailVerificationCode(env, ALICE, EMAIL);

    await expect(verifyEmailCode(env, ALICE, codes[0])).resolves.toBe(true);
    expect(await readRow()).toBeNull();
    await expect(verifyEmailCode(env, ALICE, codes[0])).resolves.toBe(false);
  });

  it('counts failed attempts and rejects after the ceiling', async () => {
    const { codes } = stubBrevo();
    const env = makeEnv();
    await issueEmailVerificationCode(env, ALICE, EMAIL);

    for (let i = 0; i < 5; i += 1) {
      await expect(verifyEmailCode(env, ALICE, wrongVariant(codes[0]))).resolves.toBe(false);
    }
    expect((await readRow())?.attempts).toBe(5);

    // Even the correct code cannot be used after the attempt ceiling.
    await expect(verifyEmailCode(env, ALICE, codes[0])).resolves.toBe(false);
    expect(await readRow()).toBeNull();
  });

  it('caps issuance per rolling day and keeps the last code valid', async () => {
    const { codes, fetchMock } = stubBrevo();
    const env = makeEnv();

    for (let i = 0; i < DAILY_EMAIL_LIMIT; i += 1) {
      const result = await issueEmailVerificationCode(env, ALICE, EMAIL);
      expect(result.sent).toBe(true);
    }

    const capped = await issueEmailVerificationCode(env, ALICE, EMAIL);

    expect(capped).toMatchObject({ sent: false, capped: true });
    expect(fetchMock).toHaveBeenCalledTimes(DAILY_EMAIL_LIMIT);
    expect((await readRow())?.daily_count).toBe(DAILY_EMAIL_LIMIT);
    expect(codes).toHaveLength(DAILY_EMAIL_LIMIT);
    await expect(verifyEmailCode(env, ALICE, codes[codes.length - 1])).resolves.toBe(true);
  });

  it('returns a usable code when email delivery is not configured', async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    const env = makeEnv('');

    const result = await issueEmailVerificationCode(env, ALICE, EMAIL);

    expect(result.sent).toBe(false);
    expect(result.capped).toBeUndefined();
    expect(result.code).toMatch(/^\d{6}$/);
    expect(fetchMock).not.toHaveBeenCalled();
    await expect(verifyEmailCode(env, ALICE, result.code!)).resolves.toBe(true);
  });
});
