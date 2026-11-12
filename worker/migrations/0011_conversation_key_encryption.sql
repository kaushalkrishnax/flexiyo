PRAGMA foreign_keys = ON;

-- Versioned message envelope. Existing rows stay version 1 and keep their
-- per-device ciphertexts in message_deliveries, so the archived Signal client
-- can still read history. New client builds write version 2 rows here.
ALTER TABLE messages ADD COLUMN ciphertext TEXT;
ALTER TABLE messages ADD COLUMN nonce TEXT;
ALTER TABLE messages ADD COLUMN auth_tag TEXT;
ALTER TABLE messages ADD COLUMN key_epoch INTEGER;
ALTER TABLE messages ADD COLUMN encryption_version INTEGER NOT NULL DEFAULT 1;

-- Message-level receipt state. Legacy receipts continue to live in
-- message_deliveries; new messages use these columns so delivery no longer
-- fans out a row per recipient device.
ALTER TABLE messages ADD COLUMN delivered_at INTEGER;
ALTER TABLE messages ADD COLUMN read_at INTEGER;

UPDATE messages
SET delivered_at = (
      SELECT MIN(md.delivered_at) FROM message_deliveries md
      WHERE md.message_id = messages.id AND md.delivered_at IS NOT NULL
    ),
    read_at = (
      SELECT MAX(md.read_at) FROM message_deliveries md
      WHERE md.message_id = messages.id AND md.read_at IS NOT NULL
    );

CREATE INDEX idx_messages_conv_version_created
  ON messages(conversation_id, encryption_version, created_at);
CREATE INDEX idx_messages_conv_unread
  ON messages(conversation_id, encryption_version, read_at);

-- Device key agreement material for conversation-key envelopes and QR pairing.
-- Version 1 devices keep using their Signal bundle columns unchanged.
ALTER TABLE devices ADD COLUMN encryption_version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE devices ADD COLUMN identity_public_key TEXT;

-- Epoch marker. A message with key_epoch below this value is stale: the sender
-- may still hold a revoked key and must not be able to keep using it.
ALTER TABLE conversations ADD COLUMN key_epoch INTEGER NOT NULL DEFAULT 0;
ALTER TABLE conversations ADD COLUMN key_rotation_required INTEGER NOT NULL DEFAULT 0;

CREATE TABLE conversation_key_epochs (
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  epoch INTEGER NOT NULL CHECK (epoch > 0),
  created_by_device_id INTEGER REFERENCES devices(id) ON DELETE SET NULL,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  PRIMARY KEY (conversation_id, epoch)
);
CREATE INDEX idx_key_epochs_conversation
  ON conversation_key_epochs(conversation_id, epoch);

-- Opaque wrapped conversation keys. Ciphertext is produced client-side by
-- sealing the conversation key to one device's X25519 identity key; the
-- Worker and D1 never see plaintext key material.
CREATE TABLE device_key_envelopes (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  epoch INTEGER NOT NULL,
  recipient_device_id INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  sender_device_id INTEGER REFERENCES devices(id) ON DELETE SET NULL,
  ephemeral_public_key TEXT NOT NULL,
  nonce TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  mac TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  UNIQUE(conversation_id, epoch, recipient_device_id),
  FOREIGN KEY (conversation_id, epoch)
    REFERENCES conversation_key_epochs(conversation_id, epoch) ON DELETE CASCADE
);
CREATE INDEX idx_key_envelopes_recipient
  ON device_key_envelopes(recipient_device_id, conversation_id, epoch);

-- QR device pairing. The server relays opaque join proofs and never receives
-- the pairing secret or any conversation key.
CREATE TABLE pairing_sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  initiator_device_id INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  initiator_ephemeral_public TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'joined', 'approved', 'cancelled', 'expired')),
  joined_installation_id TEXT,
  joined_identity_public TEXT,
  joined_ephemeral_public TEXT,
  joined_nonce TEXT,
  joined_ciphertext TEXT,
  joined_mac TEXT,
  approved_device_id INTEGER REFERENCES devices(id) ON DELETE SET NULL,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  expires_at INTEGER NOT NULL,
  approved_at INTEGER
);
CREATE INDEX idx_pairing_user_status ON pairing_sessions(user_id, status);
CREATE INDEX idx_pairing_expires ON pairing_sessions(expires_at);
