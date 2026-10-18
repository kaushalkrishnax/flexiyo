ALTER TABLE messages ADD COLUMN sender_device_id INTEGER REFERENCES devices(id) ON DELETE SET NULL;
CREATE INDEX idx_messages_sender_device ON messages(sender_device_id);
