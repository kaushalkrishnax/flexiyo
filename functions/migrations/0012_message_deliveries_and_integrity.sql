-- 0012_message_deliveries_and_integrity.sql
-- Audit fixes:
--  1. Conversations: canonical participant ordering (user_a < user_b) is
--     normalized IN PLACE and mirrored (a,b)/(b,a) duplicate pairs are
--     collapsed, so the pre-existing UNIQUE(user_a_id, user_b_id) guarantee
--     (0001) becomes airtight. Orphaned initiated_by_id values are nulled to
--     keep data-level FK integrity. A table REBUILD to add CHECK/FK constraints
--     is deliberately NOT done here: on D1, foreign keys are always enforced
--     and dropping `messages`' parent table requires detaching/recreating
--     messages and its entire dependent chain — a disproportionate risk for
--     constraint polish that application-layer validation already covers.
--     See docs/schema.md ("Why conversations is not rebuilt") for the analysis.
--  2. Delivery state moves from per-recipient-user (message_delivery) to
--     per-recipient-device (message_deliveries), carrying a per-device
--     ciphertext payload plus sender_device_id so each receiving device knows
--     which session decrypted which payload. All existing rows are converted.
--     The old table is retained (renamed) as message_delivery_legacy until the
--     conversion is verified in production, then droppable.
--  3. messages.encrypted_payload remains as the legacy single-payload column
--     (deprecated) so pre-migration messages whose recipient-device mapping is
--     unknown stay readable. It is no longer written by new sends.

-- ---------------------------------------------------------------------------
-- 1a. Null out initiated_by_id values that no longer resolve to a users row
--     (data-level equivalent of the FK that a rebuild could not add safely).
UPDATE conversations
SET initiated_by_id = NULL
WHERE initiated_by_id IS NOT NULL
  AND initiated_by_id NOT IN (SELECT id FROM users);

-- 1b. Map mirrored duplicate pairs (a,b)/(b,a) onto a single winner row
--     (most recent activity wins). Children of losing rows are repointed to
--     the winner before the losers are removed.
CREATE TABLE conv_migration_map (
  loser_id  TEXT PRIMARY KEY,
  winner_id TEXT NOT NULL
);

INSERT INTO conv_migration_map (loser_id, winner_id)
SELECT loser_id, winner_id
FROM (
  SELECT
    c.id AS loser_id,
    (
      SELECT c2.id
      FROM conversations c2
      WHERE (CASE WHEN c2.user_a_id < c2.user_b_id THEN c2.user_a_id ELSE c2.user_b_id END)
          = (CASE WHEN c.user_a_id < c.user_b_id THEN c.user_a_id ELSE c.user_b_id END)
        AND (CASE WHEN c2.user_a_id < c2.user_b_id THEN c2.user_b_id ELSE c2.user_a_id END)
          = (CASE WHEN c.user_a_id < c.user_b_id THEN c.user_b_id ELSE c.user_a_id END)
      ORDER BY COALESCE(c2.last_message_at, 0) DESC,
               c2.created_at DESC,
               c2.id ASC
      LIMIT 1
    ) AS winner_id
  FROM conversations c
)
WHERE loser_id <> winner_id;

-- Repoint child rows from losing conversations to the surviving winner.
UPDATE messages
SET conversation_id = (
  SELECT mm.winner_id FROM conv_migration_map mm
  WHERE mm.loser_id = messages.conversation_id
)
WHERE conversation_id IN (SELECT loser_id FROM conv_migration_map);

UPDATE message_reactions
SET conversation_id = (
  SELECT mm.winner_id FROM conv_migration_map mm
  WHERE mm.loser_id = message_reactions.conversation_id
)
WHERE conversation_id IN (SELECT loser_id FROM conv_migration_map);

-- conversation_user_settings has UNIQUE(conversation_id, user_id): merging two
-- rows for the same user would collide, so drop the loser's row when the
-- winner already has one (winner's settings take precedence), then repoint.
DELETE FROM conversation_user_settings
WHERE id IN (
  SELECT cus.id
  FROM conversation_user_settings cus
  JOIN conv_migration_map mm ON mm.loser_id = cus.conversation_id
  WHERE EXISTS (
    SELECT 1 FROM conversation_user_settings w
    WHERE w.conversation_id = mm.winner_id AND w.user_id = cus.user_id
  )
);

UPDATE conversation_user_settings
SET conversation_id = (
  SELECT mm.winner_id FROM conv_migration_map mm
  WHERE mm.loser_id = conversation_user_settings.conversation_id
)
WHERE conversation_id IN (SELECT loser_id FROM conv_migration_map);

DELETE FROM conversations
WHERE id IN (SELECT loser_id FROM conv_migration_map);

DROP TABLE conv_migration_map;

-- 1c. Normalize reversed rows in place (safe post-collapse: at most one row
--     per unordered pair exists, so the swap cannot collide with UNIQUE).
--     SQLite evaluates all SET expressions against the original row values,
--     so this single statement performs a true column swap.
UPDATE conversations
SET user_a_id = user_b_id, user_b_id = user_a_id
WHERE user_a_id > user_b_id;

CREATE INDEX IF NOT EXISTS idx_conversations_last_message
  ON conversations(last_message_at);

-- ---------------------------------------------------------------------------
-- 2. Per-device message delivery ledger.
--
-- Each row is the authoritative record that one ciphertext payload, encrypted
-- for exactly one recipient device by exactly one sender device, has been
-- stored for a logical message. Delivery/read timestamps are per device;
-- sender-side UI aggregates them across the recipient account's devices.
--
--  * payload/message_type: the per-device ciphertext. NULL only for legacy
--    rows whose historical ciphertext could not be attributed to a device.
--  * delivered_at: set when that specific device acknowledges receipt.
--  * read_at: set when the owning account marks the conversation read.
--  * UNIQUE(message_id, recipient_device_id) deduplicates fan-out retries.
CREATE TABLE message_deliveries (
  id                  TEXT PRIMARY KEY,
  message_id          TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  recipient_device_id INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  -- SET NULL (not CASCADE): revoking a device must never delete delivery rows
  -- that belong to other devices' receipts; the sender attribution degrades to
  -- NULL while the recipient-side records survive.
  sender_device_id    INTEGER REFERENCES devices(id) ON DELETE SET NULL,
  payload             TEXT,
  message_type        TEXT NOT NULL DEFAULT 'signal'
                        CHECK (message_type IN ('signal', 'prekey')),
  delivered_at        INTEGER,
  read_at             INTEGER,
  created_at          INTEGER NOT NULL DEFAULT (unixepoch()),
  UNIQUE (message_id, recipient_device_id)
);

-- Backfill: convert every existing per-user delivery row into a per-device row.
-- Device attribution is best-effort for historical data: prefer the device that
-- carried the legacy client device id '1' (the pre-multi-device client always
-- used that id), otherwise the account's oldest device. Delivery rows whose
-- recipient account has no device at all cannot be attributed; those messages
-- remain readable through the legacy messages.encrypted_payload column and are
-- deliberately left without a delivery row (nothing is deleted).
INSERT INTO message_deliveries (
  id, message_id, recipient_device_id, sender_device_id, payload,
  message_type, delivered_at, read_at, created_at
)
SELECT
  lower(hex(randomblob(16))),
  md.message_id,
  recipient_devices.id,
  sender_devices.id,
  m.encrypted_payload,
  CASE WHEN m.message_type IN ('signal', 'prekey') THEN m.message_type ELSE 'signal' END,
  md.delivered_at,
  md.read_at,
  COALESCE(m.created_at, unixepoch())
FROM message_delivery md
JOIN messages m ON m.id = md.message_id
JOIN devices recipient_devices
  ON recipient_devices.id = (
    SELECT d.id FROM devices d
    WHERE d.user_id = md.recipient_id
    ORDER BY CASE WHEN d.legacy_device_id = '1' THEN 0 ELSE 1 END, d.id ASC
    LIMIT 1
  )
LEFT JOIN devices sender_devices
  ON sender_devices.id = (
    SELECT d2.id FROM devices d2
    WHERE d2.user_id = m.sender_id
    ORDER BY CASE WHEN d2.legacy_device_id = '1' THEN 0 ELSE 1 END, d2.id ASC
    LIMIT 1
  );

-- Retire (but keep) the old table until the conversion has been verified.
ALTER TABLE message_delivery RENAME TO message_delivery_legacy;

CREATE INDEX idx_message_deliveries_recipient
  ON message_deliveries(recipient_device_id, read_at);
CREATE INDEX idx_message_deliveries_sender_device
  ON message_deliveries(sender_device_id);

-- ---------------------------------------------------------------------------
INSERT INTO worker_meta (key, value) VALUES ('schema_version', '0012')
  ON CONFLICT(key) DO UPDATE SET value = excluded.value;
