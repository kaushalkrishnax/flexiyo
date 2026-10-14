ALTER TABLE conversations ADD COLUMN initiated_by_id TEXT;
ALTER TABLE conversations ADD COLUMN request_status TEXT NOT NULL DEFAULT 'accepted';