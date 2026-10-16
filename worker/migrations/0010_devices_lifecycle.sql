-- 0010_devices_lifecycle.sql
-- Devices become first-class multi-device records with lifecycle states.
--
-- Changes:
--  * id becomes an INTEGER PRIMARY KEY AUTOINCREMENT. This is the server-assigned
--    Signal device id (libsignal addresses use integer device ids). AUTOINCREMENT
--    guarantees ids are never reused after a device is removed, so Signal session
--    addresses can never silently point at a different device.
--  * installation_id (TEXT): stable client-generated id identifying a physical
--    install across re-registrations. Migrated from the old TEXT devices.device_id.
--  * legacy_device_id: preserves the old TEXT id for audit/migration traceability
--    and for the message-delivery backfill in 0012. Transitional column; safe to
--    drop in a future cleanup migration.
--  * status: 'active' | 'pending' | 'disabled' | 'logged_out' (CHECK-constrained).
--    Only 'active' and 'pending' devices count toward the per-account device limit
--    and only 'active' devices are served in key bundles.
--  * last_seen_at / revoked_at: lifecycle metadata.
--
-- Data migration: every existing device row is carried over as an 'active'
-- device. No device rows are deleted.

CREATE TABLE devices_v2 (
  id                        INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id                   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  installation_id           TEXT NOT NULL,
  legacy_device_id          TEXT,
  registration_id           INTEGER NOT NULL,
  identity_key              TEXT NOT NULL,
  signed_pre_key_id         INTEGER NOT NULL,
  signed_pre_key_public     TEXT NOT NULL,
  signed_pre_key_signature  TEXT NOT NULL,
  status                    TEXT NOT NULL DEFAULT 'active'
                              CHECK (status IN ('active', 'pending', 'disabled', 'logged_out')),
  created_at                INTEGER NOT NULL DEFAULT (unixepoch()),
  last_seen_at              INTEGER,
  revoked_at                INTEGER,
  UNIQUE (user_id, installation_id)
);

INSERT INTO devices_v2 (
  user_id, installation_id, legacy_device_id, registration_id, identity_key,
  signed_pre_key_id, signed_pre_key_public, signed_pre_key_signature,
  status, created_at, last_seen_at
)
SELECT
  user_id, device_id, device_id, registration_id, identity_key,
  signed_pre_key_id, signed_pre_key_public, signed_pre_key_signature,
  'active', created_at, created_at
FROM devices;

DROP TABLE devices;
ALTER TABLE devices_v2 RENAME TO devices;

CREATE INDEX idx_devices_user_status ON devices(user_id, status);
CREATE INDEX idx_devices_user_created ON devices(user_id, created_at);

INSERT INTO worker_meta (key, value) VALUES ('schema_version', '0010')
  ON CONFLICT(key) DO UPDATE SET value = excluded.value;