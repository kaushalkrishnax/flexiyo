-- 0013_email_verification_codes.sql
-- One active single-use email verification code per user.
-- Stores hashes only — the raw 6-digit code exists in the Brevo email and
-- nowhere else. Re-issuing a code overwrites the previous record (covers
-- resend), so a user never has two racing codes.

CREATE TABLE IF NOT EXISTS email_verification_codes (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL UNIQUE,
  email TEXT NOT NULL,
  code_hash TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_email_codes_expiry ON email_verification_codes(expires_at);
