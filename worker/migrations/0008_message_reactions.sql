-- 0008_message_reactions.sql
-- Table for message reactions (per-user single emoji reaction) and schema improvements

CREATE TABLE IF NOT EXISTS message_reactions (
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  emoji TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  UNIQUE(message_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_reactions_message ON message_reactions(message_id);
CREATE INDEX IF NOT EXISTS idx_reactions_conv ON message_reactions(conversation_id);
CREATE INDEX IF NOT EXISTS idx_reactions_user ON message_reactions(user_id);

-- Add reaction column to messages for fast indexed retrieval
ALTER TABLE messages ADD COLUMN reaction TEXT;

-- Improve users table: add clean password column (avoiding redundant _hash suffix)
ALTER TABLE users ADD COLUMN password TEXT;
UPDATE users SET password = password_hash WHERE password IS NULL OR password = '';
