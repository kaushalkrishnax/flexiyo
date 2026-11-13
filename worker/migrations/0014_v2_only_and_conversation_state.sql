PRAGMA foreign_keys = ON;

DROP TABLE IF EXISTS message_deliveries;
DROP TABLE IF EXISTS pre_keys;

DELETE FROM messages WHERE encryption_version != 2;
DELETE FROM devices WHERE encryption_version != 2;

DROP INDEX IF EXISTS idx_messages_conv_version_created;
DROP INDEX IF EXISTS idx_messages_conv_unread;
DROP INDEX IF EXISTS idx_messages_conv_unsent;
DROP INDEX IF EXISTS idx_messages_conv_v1_active_sender;
DROP INDEX IF EXISTS idx_messages_conv_v2_sender_read;

ALTER TABLE messages DROP COLUMN encryption_version;

ALTER TABLE devices DROP COLUMN legacy_device_id;
ALTER TABLE devices DROP COLUMN registration_id;
ALTER TABLE devices DROP COLUMN identity_key;
ALTER TABLE devices DROP COLUMN signed_pre_key_id;
ALTER TABLE devices DROP COLUMN signed_pre_key_public;
ALTER TABLE devices DROP COLUMN signed_pre_key_signature;
ALTER TABLE devices DROP COLUMN encryption_version;

ALTER TABLE conversations
  ADD COLUMN last_message_sender_id TEXT REFERENCES users(id) ON DELETE SET NULL;

UPDATE conversations
SET
  last_message_at = (
    SELECT m.created_at
    FROM messages m
    WHERE m.conversation_id = conversations.id AND m.is_unsent = 0
    ORDER BY m.created_at DESC, m.id DESC
    LIMIT 1
  ),
  last_message_sender_id = (
    SELECT m.sender_id
    FROM messages m
    WHERE m.conversation_id = conversations.id AND m.is_unsent = 0
    ORDER BY m.created_at DESC, m.id DESC
    LIMIT 1
  );

CREATE INDEX IF NOT EXISTS idx_messages_conv_sender_read
  ON messages(conversation_id, sender_id, read_at)
  WHERE is_unsent = 0;

CREATE TABLE IF NOT EXISTS conversation_user_state (
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  unread_count INTEGER NOT NULL DEFAULT 0,
  last_read_at INTEGER,
  peer_seen_at INTEGER,
  PRIMARY KEY (conversation_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_conversation_user_state_user
  ON conversation_user_state(user_id, conversation_id);

INSERT OR REPLACE INTO conversation_user_state (
  conversation_id,
  user_id,
  unread_count,
  last_read_at,
  peer_seen_at
)
SELECT
  p.conversation_id,
  p.user_id,
  COALESCE(SUM(CASE WHEN m.sender_id != p.user_id AND m.read_at IS NULL THEN 1 ELSE 0 END), 0) AS unread_count,
  MAX(CASE WHEN m.sender_id != p.user_id THEN m.read_at ELSE NULL END) AS last_read_at,
  MAX(CASE WHEN m.sender_id = p.user_id THEN m.read_at ELSE NULL END) AS peer_seen_at
FROM (
  SELECT id AS conversation_id, user_a_id AS user_id FROM conversations
  UNION ALL
  SELECT id AS conversation_id, user_b_id AS user_id FROM conversations
) p
LEFT JOIN messages m
  ON m.conversation_id = p.conversation_id
  AND m.is_unsent = 0
GROUP BY p.conversation_id, p.user_id;
