import { integer, sqliteTable, text, index } from 'drizzle-orm/sqlite-core';

export const users = sqliteTable(
  'users',
  {
    id: text('id').primaryKey(),
    username: text('username').notNull().unique(),
    passwordHash: text('password_hash').notNull(),
    createdAt: integer('created_at').notNull().default(0),
  },
  (table) => ({
    usernameIdx: index('idx_users_username').on(table.username),
  }),
);

export const tokenRevocations = sqliteTable('token_revocations', {
  jti: text('jti').primaryKey(),
  userId: text('user_id').notNull(),
  expiresAt: integer('expires_at').notNull(),
});

export const devices = sqliteTable(
  'devices',
  {
    id: text('id').primaryKey(),
    userId: text('user_id').notNull().references(() => users.id),
    deviceId: text('device_id').notNull(),
    registrationId: integer('registration_id').notNull(),
    identityKey: text('identity_key').notNull(),
    signedPreKeyId: integer('signed_pre_key_id').notNull(),
    signedPreKeyPublic: text('signed_pre_key_public').notNull(),
    signedPreKeySignature: text('signed_pre_key_signature').notNull(),
    createdAt: integer('created_at').notNull().default(0),
  },
  (table) => ({
    userIdIdx: index('idx_devices_user_id').on(table.userId),
  }),
);

export const preKeys = sqliteTable(
  'pre_keys',
  {
    id: text('id').primaryKey(),
    userId: text('user_id').notNull().references(() => users.id),
    keyId: integer('key_id').notNull(),
    publicKey: text('public_key').notNull(),
    used: integer('used').notNull().default(0),
    createdAt: integer('created_at').notNull().default(0),
  },
  (table) => ({
    userUsedIdx: index('idx_pre_keys_user_id_used').on(table.userId, table.used),
  }),
);

export const conversations = sqliteTable(
  'conversations',
  {
    id: text('id').primaryKey(),
    userAId: text('user_a_id').notNull().references(() => users.id),
    userBId: text('user_b_id').notNull().references(() => users.id),
    initiatedById: text('initiated_by_id'),
    requestStatus: text('request_status').notNull().default('accepted'),
    disappearingTimer: integer('disappearing_timer').notNull().default(0),
    createdAt: integer('created_at').notNull().default(0),
    lastMessageAt: integer('last_message_at'),
  },
  (table) => ({
    userAIdx: index('idx_conversations_user_a').on(table.userAId),
    userBIdx: index('idx_conversations_user_b').on(table.userBId),
  }),
);

export const messages = sqliteTable(
  'messages',
  {
    id: text('id').primaryKey(),
    conversationId: text('conversation_id').notNull().references(() => conversations.id),
    senderId: text('sender_id').notNull().references(() => users.id),
    encryptedPayload: text('encrypted_payload'),
    messageType: text('message_type').notNull().default('signal'),
    replyToId: text('reply_to_id'),
    version: integer('version').notNull().default(1),
    isUnsent: integer('is_unsent').notNull().default(0),
    createdAt: integer('created_at').notNull().default(0),
    expiresAt: integer('expires_at'),
    editedAt: integer('edited_at'),
    systemData: text('system_data'),
  },
  (table) => ({
    conversationCreatedIdx: index('idx_messages_conv_created').on(table.conversationId, table.createdAt),
    expiresIdx: index('idx_messages_expires').on(table.expiresAt),
  }),
);

export const localDeletions = sqliteTable(
  'local_deletions',
  {
    id: text('id').primaryKey(),
    userId: text('user_id').notNull().references(() => users.id),
    messageId: text('message_id').notNull().references(() => messages.id),
    deletedAt: integer('deleted_at').notNull().default(0),
  },
  (table) => ({
    userIdx: index('idx_local_del_user').on(table.userId),
  }),
);

export const messageDelivery = sqliteTable(
  'message_delivery',
  {
    id: text('id').primaryKey(),
    messageId: text('message_id').notNull().references(() => messages.id),
    recipientId: text('recipient_id').notNull().references(() => users.id),
    deliveredAt: integer('delivered_at'),
    readAt: integer('read_at'),
  },
  (table) => ({
    messageRecipientIdx: index('idx_message_delivery_message_recipient').on(table.messageId, table.recipientId),
  }),
);

export const SCHEMA_SQL = `
-- generated via drizzle schema for documentation; see /functions/src/database/schema.ts
`;
