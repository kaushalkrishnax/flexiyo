-- Targeted indexes for inbox aggregates and read-receipt updates.
-- Partial indexes keep hot working sets smaller as message history grows.

-- Latest active message and unsent-message existence checks in inbox queries.
CREATE INDEX IF NOT EXISTS idx_messages_conv_active_latest
  ON messages(conversation_id, created_at DESC, id DESC)
  WHERE is_unsent = 0;

CREATE INDEX IF NOT EXISTS idx_messages_conv_unsent
  ON messages(conversation_id)
  WHERE is_unsent = 1;

-- Conversation-scoped v1 messages used by unread and peer-seen aggregates.
CREATE INDEX IF NOT EXISTS idx_messages_conv_v1_active_sender
  ON messages(conversation_id, sender_id, id)
  WHERE is_unsent = 0 AND encryption_version = 1;

-- One index supports both unread and read v2 message aggregates.
CREATE INDEX IF NOT EXISTS idx_messages_conv_v2_sender_read
  ON messages(conversation_id, sender_id, read_at)
  WHERE is_unsent = 0 AND encryption_version = 2;

-- Read endpoints and inbox unread aggregates only need un-read delivery rows.
-- Message-first order matches the conversation-scoped target message set.
CREATE INDEX IF NOT EXISTS idx_deliveries_unread_message_device
  ON message_deliveries(message_id, recipient_device_id)
  WHERE read_at IS NULL;

-- Peer-seen aggregation only needs delivery rows with a read timestamp.
CREATE INDEX IF NOT EXISTS idx_deliveries_read_message_timestamp
  ON message_deliveries(message_id, read_at)
  WHERE read_at IS NOT NULL;
