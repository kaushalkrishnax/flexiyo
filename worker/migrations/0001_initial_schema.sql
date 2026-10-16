-- Users
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  username TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX idx_users_username ON users(username);

-- Token revocations (for logout)
CREATE TABLE IF NOT EXISTS token_revocations (
  jti TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);

-- Devices
CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  device_id TEXT NOT NULL,
  registration_id INTEGER NOT NULL,
  identity_key TEXT NOT NULL,
  signed_pre_key_id INTEGER NOT NULL,
  signed_pre_key_public TEXT NOT NULL,
  signed_pre_key_signature TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  UNIQUE(user_id, device_id)
);
CREATE INDEX idx_devices_user_id ON devices(user_id);

-- Pre-keys
CREATE TABLE IF NOT EXISTS pre_keys (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  key_id INTEGER NOT NULL,
  public_key TEXT NOT NULL,
  used INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  UNIQUE(user_id, key_id)
);
CREATE INDEX idx_pre_keys_user_id_used ON pre_keys(user_id, used);

-- Conversations
CREATE TABLE IF NOT EXISTS conversations (
  id TEXT PRIMARY KEY,
  user_a_id TEXT NOT NULL REFERENCES users(id),
  user_b_id TEXT NOT NULL REFERENCES users(id),
  disappearing_timer INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  last_message_at INTEGER,
  UNIQUE(user_a_id, user_b_id)
);
CREATE INDEX idx_conversations_user_a ON conversations(user_a_id);
CREATE INDEX idx_conversations_user_b ON conversations(user_b_id);

-- Messages
CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id),
  sender_id TEXT NOT NULL REFERENCES users(id),
  encrypted_payload TEXT,
  message_type TEXT NOT NULL DEFAULT 'signal',
  version INTEGER NOT NULL DEFAULT 1,
  is_unsent INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  expires_at INTEGER,
  edited_at INTEGER
);
CREATE INDEX idx_messages_conv_created ON messages(conversation_id, created_at);
CREATE INDEX idx_messages_expires ON messages(expires_at) WHERE expires_at IS NOT NULL;

-- Locally deleted messages (per-user soft delete — NOT synced)
CREATE TABLE IF NOT EXISTS local_deletions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  message_id TEXT NOT NULL REFERENCES messages(id),
  deleted_at INTEGER NOT NULL DEFAULT (unixepoch()),
  UNIQUE(user_id, message_id)
);
CREATE INDEX idx_local_del_user ON local_deletions(user_id);

-- Delivery/sync state
CREATE TABLE IF NOT EXISTS message_delivery (
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL REFERENCES messages(id),
  recipient_id TEXT NOT NULL REFERENCES users(id),
  delivered_at INTEGER,
  UNIQUE(message_id, recipient_id)
);
