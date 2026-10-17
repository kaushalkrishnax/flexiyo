PRAGMA foreign_keys = ON;

CREATE TABLE media (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('image', 'voice')),
  view_policy TEXT NOT NULL DEFAULT 'unlimited'
    CHECK (view_policy IN ('once', 'twice', 'unlimited')),
  size INTEGER NOT NULL CHECK (size > 0),
  mime_type TEXT,
  r2_key TEXT NOT NULL UNIQUE,
  duration_ms INTEGER,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  expires_at INTEGER NOT NULL,
  consumed INTEGER NOT NULL DEFAULT 0 CHECK (consumed IN (0, 1))
);
CREATE INDEX idx_media_conversation ON media(conversation_id);
CREATE INDEX idx_media_expires ON media(expires_at);

CREATE TABLE media_views (
  media_id TEXT NOT NULL REFERENCES media(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  count INTEGER NOT NULL DEFAULT 1,
  updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
  PRIMARY KEY(media_id, user_id)
);
CREATE INDEX idx_media_views_media ON media_views(media_id);

CREATE TABLE daily_usage (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  day TEXT NOT NULL,
  bytes_up INTEGER NOT NULL DEFAULT 0,
  bytes_down INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(user_id, day)
);
CREATE INDEX idx_daily_usage_day ON daily_usage(day);
