-- User search is `username LIKE '<prefix>%'` with LIMIT 20. The LIKE operator is
-- case-insensitive (ASCII) by default, so SQLite cannot use the UNIQUE BINARY
-- index on username and falls back to `SCAN users`; a prefix that matches
-- nothing still reads every user row. A NOCASE index preserves the existing
-- case-insensitive semantics and lets the LIKE optimization do a range seek.
CREATE INDEX IF NOT EXISTS idx_users_username_nocase
  ON users(username COLLATE NOCASE);
