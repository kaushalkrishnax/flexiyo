-- 0009_users_and_sessions.sql
-- Audit fixes:
--  1. users.password duplicated users.password_hash (added by 0008, never read by
--     any code path — auth only ever reads password_hash). Drop the duplicate so a
--     single secret column remains. Non-destructive for real data: password_hash is
--     untouched.
--  2. _worker_meta was created ad-hoc at runtime by services/expiry.ts. Promote it
--     to a real, migration-managed table named worker_meta (no leading underscore)
--     and stop runtime CREATE TABLE. Only a cleanup timestamp lived in the old
--     table, so no data copy is required.
--  3. token_revocations gains a foreign key to users (account isolation) and an
--     index on expires_at so expired revocations can be pruned cheaply.

-- 1. Drop the redundant password column. SQLite >= 3.35 (D1) supports DROP COLUMN.
--    It has no index/CHECK dependencies, so this is safe.
ALTER TABLE users DROP COLUMN password;

-- 2. Worker bookkeeping (replaces runtime-created _worker_meta).
CREATE TABLE IF NOT EXISTS worker_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- 3. Session revocations: rebuild with FK + expiry index. All rows are carried
--    over verbatim (no data loss).
CREATE TABLE token_revocations_v2 (
  jti        TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL
);
INSERT INTO token_revocations_v2 (jti, user_id, expires_at)
  SELECT jti, user_id, expires_at FROM token_revocations;
DROP TABLE token_revocations;
ALTER TABLE token_revocations_v2 RENAME TO token_revocations;
CREATE INDEX idx_token_revocations_expires ON token_revocations(expires_at);
CREATE INDEX idx_token_revocations_user ON token_revocations(user_id);

-- Record schema version for operational visibility.
INSERT INTO worker_meta (key, value) VALUES ('schema_version', '0009')
  ON CONFLICT(key) DO UPDATE SET value = excluded.value;