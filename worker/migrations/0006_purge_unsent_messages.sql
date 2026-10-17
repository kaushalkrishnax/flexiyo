DELETE FROM messages WHERE is_unsent = 1;

UPDATE conversations
SET last_message_at = (
  SELECT MAX(messages.created_at)
  FROM messages
  WHERE messages.conversation_id = conversations.id
    AND messages.is_unsent = 0
);
