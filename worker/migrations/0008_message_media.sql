ALTER TABLE messages ADD COLUMN media_id TEXT REFERENCES media(id) ON DELETE SET NULL;
CREATE INDEX idx_messages_media ON messages(media_id);
