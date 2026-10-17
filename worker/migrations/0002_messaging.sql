PRAGMA foreign_keys = ON;

CREATE TABLE conversations (
  id TEXT PRIMARY KEY,
  user_a_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_b_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  initiated_by_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  request_status TEXT NOT NULL DEFAULT 'accepted'
    CHECK (request_status IN ('pending', 'accepted', 'rejected')),
  disappearing_timer INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  last_message_at INTEGER,
  UNIQUE(user_a_id, user_b_id),
  CHECK (user_a_id <> user_b_id)
);
CREATE INDEX idx_conversations_user_a ON conversations(user_a_id);
CREATE INDEX idx_conversations_user_b ON conversations(user_b_id);
CREATE INDEX idx_conversations_last_message ON conversations(last_message_at);

CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  encrypted_payload TEXT,
  message_type TEXT NOT NULL DEFAULT 'signal'
    CHECK (message_type IN ('signal', 'prekey', 'system')),
  reply_to_id TEXT REFERENCES messages(id) ON DELETE SET NULL,
  version INTEGER NOT NULL DEFAULT 1,
  is_unsent INTEGER NOT NULL DEFAULT 0 CHECK (is_unsent IN (0, 1)),
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  expires_at INTEGER,
  edited_at INTEGER,
  system_data TEXT,
  reaction TEXT
);
CREATE INDEX idx_messages_conv_created ON messages(conversation_id, created_at);
CREATE INDEX idx_messages_expires ON messages(expires_at);

CREATE TABLE message_deliveries (
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  recipient_device_id INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  sender_device_id INTEGER REFERENCES devices(id) ON DELETE SET NULL,
  payload TEXT,
  message_type TEXT NOT NULL DEFAULT 'signal'
    CHECK (message_type IN ('signal', 'prekey')),
  delivered_at INTEGER,
  read_at INTEGER,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  UNIQUE(message_id, recipient_device_id)
);
CREATE INDEX idx_deliveries_device_message
  ON message_deliveries(recipient_device_id, message_id);
CREATE INDEX idx_deliveries_message ON message_deliveries(message_id);
CREATE INDEX idx_deliveries_sender_device ON message_deliveries(sender_device_id);

CREATE TABLE local_deletions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  deleted_at INTEGER NOT NULL DEFAULT (unixepoch()),
  UNIQUE(user_id, message_id)
);
CREATE INDEX idx_local_deletions_user ON local_deletions(user_id);

CREATE TABLE message_reactions (
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  emoji TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
  UNIQUE(message_id, user_id)
);
CREATE INDEX idx_reactions_message ON message_reactions(message_id);
CREATE INDEX idx_reactions_conversation ON message_reactions(conversation_id);
CREATE INDEX idx_reactions_user ON message_reactions(user_id);

CREATE TABLE conversation_user_settings (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  is_pinned INTEGER NOT NULL DEFAULT 0 CHECK (is_pinned IN (0, 1)),
  is_muted INTEGER NOT NULL DEFAULT 0 CHECK (is_muted IN (0, 1)),
  is_restricted INTEGER NOT NULL DEFAULT 0 CHECK (is_restricted IN (0, 1)),
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
  UNIQUE(conversation_id, user_id)
);
CREATE INDEX idx_conv_settings_user ON conversation_user_settings(user_id);
CREATE INDEX idx_conv_settings_conversation_user
  ON conversation_user_settings(conversation_id, user_id);

CREATE TABLE user_blocks (
  id TEXT PRIMARY KEY,
  blocker_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  UNIQUE(blocker_id, blocked_id),
  CHECK (blocker_id <> blocked_id)
);
CREATE INDEX idx_user_blocks_blocker ON user_blocks(blocker_id);
CREATE INDEX idx_user_blocks_blocked ON user_blocks(blocked_id);
