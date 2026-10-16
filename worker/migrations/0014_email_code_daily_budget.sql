-- 0014_email_code_daily_budget.sql
-- Rolling 24h budget for verification emails per user (reset by the Worker on
-- re-issue), enforced inside the upsert's WHERE gate — no extra round trips.

ALTER TABLE email_verification_codes ADD COLUMN daily_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE email_verification_codes ADD COLUMN window_started_at INTEGER NOT NULL DEFAULT 0;
