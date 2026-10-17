PRAGMA foreign_keys = ON;

CREATE TABLE users (
  id TEXT PRIMARY KEY,
  username TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  email TEXT,
  google_id TEXT,
  email_verified INTEGER NOT NULL DEFAULT 0 CHECK (email_verified IN (0, 1)),
  created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_google_id ON users(google_id);

CREATE TABLE token_revocations (
  jti TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL
);
CREATE INDEX idx_token_revocations_expires ON token_revocations(expires_at);
CREATE INDEX idx_token_revocations_user ON token_revocations(user_id);

CREATE TABLE worker_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE devices (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  installation_id TEXT NOT NULL,
  legacy_device_id TEXT,
  registration_id INTEGER NOT NULL,
  identity_key TEXT NOT NULL,
  signed_pre_key_id INTEGER NOT NULL,
  signed_pre_key_public TEXT NOT NULL,
  signed_pre_key_signature TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'pending', 'disabled', 'logged_out')),
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  last_seen_at INTEGER,
  revoked_at INTEGER,
  UNIQUE(user_id, installation_id)
);
CREATE INDEX idx_devices_user_status ON devices(user_id, status);
CREATE INDEX idx_devices_user_created ON devices(user_id, created_at);

CREATE TABLE pre_keys (
  id TEXT PRIMARY KEY,
  device_id INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  key_id INTEGER NOT NULL,
  public_key TEXT NOT NULL,
  consumed_at INTEGER,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  UNIQUE(device_id, key_id)
);
CREATE INDEX idx_pre_keys_device_consumed ON pre_keys(device_id, consumed_at);

CREATE TABLE email_verification_codes (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  code_hash TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  daily_count INTEGER NOT NULL DEFAULT 0,
  window_started_at INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_email_codes_expiry ON email_verification_codes(expires_at);
