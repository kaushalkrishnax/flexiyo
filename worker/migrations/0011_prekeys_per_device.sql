-- 0011_prekeys_per_device.sql
-- One-time pre-keys become device-scoped, as required by the Signal Protocol.
--
-- Changes:
--  * pre_keys.device_id (FK -> devices.id, ON DELETE CASCADE) replaces
--    pre_keys.user_id. Key identity is now (device_id, key_id) instead of
--    (user_id, key_id): one account can hold up to 5 devices, each with its own
--    independent one-time pre-key set.
--  * used INTEGER flag becomes consumed_at INTEGER (NULL = still available).
--    The timestamp records when the key was handed out, enabling auditability
--    and delayed purge of consumed keys.
--
-- Data migration (no cryptographic record is deleted):
--  * Each existing user's pre-keys attach to that user's oldest device (the
--    system was effectively single-device, so this is the device that owned
--    them in practice).
--  * Users that have pre-keys but NO device row (orphaned crypto state that can
--    never be served correctly) receive a synthetic device with
--    installation_id 'legacy-unknown' and status 'disabled'. Disabled devices
--    are never served and never count toward the device limit, so the orphaned
--    keys are preserved but inert — matching their real-world usability.

-- Synthetic devices for accounts whose pre-keys have no owning device.
INSERT INTO devices (
  user_id, installation_id, legacy_device_id, registration_id, identity_key,
  signed_pre_key_id, signed_pre_key_public, signed_pre_key_signature,
  status, created_at
)
SELECT DISTINCT
  u.id, 'legacy-unknown', NULL, 1, 'legacy',
  0, 'legacy', 'legacy',
  'disabled', u.created_at
FROM pre_keys pk
JOIN users u ON u.id = pk.user_id
WHERE NOT EXISTS (SELECT 1 FROM devices d WHERE d.user_id = pk.user_id);

CREATE TABLE pre_keys_v2 (
  id           TEXT PRIMARY KEY,
  device_id    INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  key_id       INTEGER NOT NULL,
  public_key   TEXT NOT NULL,
  consumed_at  INTEGER,
  created_at   INTEGER NOT NULL DEFAULT (unixepoch()),
  UNIQUE (device_id, key_id)
);

-- Attach every pre-key to its owner's primary (oldest) device. MIN(id) is the
-- oldest device because integer ids are assigned in insertion order and
-- synthetic devices are created after all real devices. Each user maps to
-- exactly one device, so the historical UNIQUE(user_id, key_id) guarantee is
-- preserved under UNIQUE(device_id, key_id).
INSERT INTO pre_keys_v2 (id, device_id, key_id, public_key, consumed_at, created_at)
SELECT
  pk.id,
  primary_devices.primary_device_id,
  pk.key_id,
  pk.public_key,
  CASE WHEN pk.used = 1 THEN pk.created_at ELSE NULL END,
  pk.created_at
FROM pre_keys pk
JOIN (
  SELECT user_id, MIN(id) AS primary_device_id
  FROM devices
  GROUP BY user_id
) primary_devices ON primary_devices.user_id = pk.user_id;

DROP TABLE pre_keys;
ALTER TABLE pre_keys_v2 RENAME TO pre_keys;

CREATE INDEX idx_pre_keys_device_consumed ON pre_keys(device_id, consumed_at);

INSERT INTO worker_meta (key, value) VALUES ('schema_version', '0011')
  ON CONFLICT(key) DO UPDATE SET value = excluded.value;