-- Device tokens for push notification delivery (Firebase Cloud Messaging).
-- One token per app install; re-registering reassigns ownership to the user
-- who is currently signed in on that device.

CREATE TABLE push_tokens (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token TEXT NOT NULL UNIQUE,
  platform TEXT NOT NULL DEFAULT 'android'
    CHECK (platform IN ('android', 'ios')),
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX idx_push_tokens_user ON push_tokens(user_id);
