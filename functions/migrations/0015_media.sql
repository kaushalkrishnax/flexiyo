-- R2 media delivery: ciphertext-only storage plus view/quota bookkeeping.

CREATE TABLE IF NOT EXISTS media (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  sender_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('image', 'voice')),
  view_policy TEXT NOT NULL DEFAULT 'unlimited' CHECK (view_policy IN ('once', 'twice', 'unlimited')),
  size INTEGER NOT NULL,
  mime_type TEXT,
  r2_key TEXT NOT NULL,
  duration_ms INTEGER,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (conversation_id) REFERENCES conversations(id)
);

CREATE TABLE IF NOT EXISTS media_views (
  media_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  count INTEGER NOT NULL DEFAULT 1,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (media_id, user_id),
  FOREIGN KEY (media_id) REFERENCES media(id)
);

CREATE TABLE IF NOT EXISTS daily_usage (
  user_id TEXT NOT NULL,
  day TEXT NOT NULL,
  bytes_up INTEGER NOT NULL DEFAULT 0,
  bytes_down INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, day)
);

CREATE INDEX IF NOT EXISTS idx_media_conversation ON media(conversation_id);
CREATE INDEX IF NOT EXISTS idx_media_expires ON media(expires_at);
CREATE INDEX IF NOT EXISTS idx_media_views_media ON media_views(media_id);
CREATE INDEX IF NOT EXISTS idx_daily_usage_day ON daily_usage(day);
