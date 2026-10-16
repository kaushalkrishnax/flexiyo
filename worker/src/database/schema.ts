import { integer, sqliteTable, text, index, unique } from 'drizzle-orm/sqlite-core';

// ---------------------------------------------------------------------------
// Post-audit schema mirror (migrations 0001..0012 applied).
// Authoritative DDL lives in worker/migrations/*.sql; this file is the
// drizzle-orm view used by auth/users routes. Keep them in sync.
// ---------------------------------------------------------------------------

export const users = sqliteTable(
  'users',
  {
    id: text('id').primaryKey(),
    username: text('username').notNull().unique(),
    passwordHash: text('password_hash').notNull(),
    email: text('email'),
    googleId: text('google_id'),
    emailVerified: integer('email_verified').notNull().default(0),
    createdAt: integer('created_at').notNull().default(0),
  },
  (table) => ({
    usernameIdx: index('idx_users_username').on(table.username),
    emailIdx: index('idx_users_email').on(table.email),
    googleIdIdx: index('idx_users_google_id').on(table.googleId),
  }),
);

export const tokenRevocations = sqliteTable(
  'token_revocations',
  {
    jti: text('jti').primaryKey(),
    userId: text('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    expiresAt: integer('expires_at').notNull(),
  },
  (table) => ({
    expiresIdx: index('idx_token_revocations_expires').on(table.expiresAt),
    userIdx: index('idx_token_revocations_user').on(table.userId),
  }),
);

/** Worker bookkeeping (migration-managed since 0009; replaces runtime _worker_meta). */
export const workerMeta = sqliteTable('worker_meta', {
  key: text('key').primaryKey(),
  value: text('value').notNull(),
});

export const devices = sqliteTable(
  'devices',
  {
    // Server-assigned Signal device id (integer, never reused via AUTOINCREMENT).
    id: integer('id').primaryKey({ autoIncrement: true }),
    userId: text('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    // Stable client-generated install id; (user_id, installation_id) is unique.
    installationId: text('installation_id').notNull(),
    legacyDeviceId: text('legacy_device_id'),
    registrationId: integer('registration_id').notNull(),
    identityKey: text('identity_key').notNull(),
    signedPreKeyId: integer('signed_pre_key_id').notNull(),
    signedPreKeyPublic: text('signed_pre_key_public').notNull(),
    signedPreKeySignature: text('signed_pre_key_signature').notNull(),
    status: text('status').notNull().default('active'),
    createdAt: integer('created_at').notNull().default(0),
    lastSeenAt: integer('last_seen_at'),
    revokedAt: integer('revoked_at'),
  },
  (table) => ({
    userStatusIdx: index('idx_devices_user_status').on(table.userId, table.status),
    userCreatedIdx: index('idx_devices_user_created').on(table.userId, table.createdAt),
    userInstallationUniq: unique('uq_devices_user_installation').on(
      table.userId,
      table.installationId,
    ),
  }),
);

export const preKeys = sqliteTable(
  'pre_keys',
  {
    id: text('id').primaryKey(),
    // Device-scoped since 0011 (Signal requires per-device one-time keys).
    deviceId: integer('device_id')
      .notNull()
      .references(() => devices.id, { onDelete: 'cascade' }),
    keyId: integer('key_id').notNull(),
    publicKey: text('public_key').notNull(),
    // NULL = available; timestamp = consumed (replaces legacy `used` flag).
    consumedAt: integer('consumed_at'),
    createdAt: integer('created_at').notNull().default(0),
  },
  (table) => ({
    deviceConsumedIdx: index('idx_pre_keys_device_consumed').on(
      table.deviceId,
      table.consumedAt,
    ),
    deviceKeyUniq: unique('uq_pre_keys_device_key').on(table.deviceId, table.keyId),
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
    reaction: text('reaction'),
  },
  (table) => ({
    conversationCreatedIdx: index('idx_messages_conv_created').on(table.conversationId, table.createdAt),
    expiresIdx: index('idx_messages_expires').on(table.expiresAt),
  }),
);

export const messageReactions = sqliteTable(
  'message_reactions',
  {
    id: text('id').primaryKey(),
    messageId: text('message_id').notNull().references(() => messages.id),
    conversationId: text('conversation_id').notNull().references(() => conversations.id),
    userId: text('user_id').notNull().references(() => users.id),
    emoji: text('emoji').notNull(),
    createdAt: integer('created_at').notNull().default(0),
    updatedAt: integer('updated_at').notNull().default(0),
  },
  (table) => ({
    messageIdx: index('idx_reactions_message').on(table.messageId),
    convIdx: index('idx_reactions_conv').on(table.conversationId),
    userIdx: index('idx_reactions_user').on(table.userId),
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

export const emailVerificationCodes = sqliteTable(
  'email_verification_codes',
  {
    id: text('id').primaryKey(),
    userId: text('user_id')
      .notNull()
      .unique()
      .references(() => users.id, { onDelete: 'cascade' }),
    email: text('email').notNull(),
    codeHash: text('code_hash').notNull(),
    expiresAt: integer('expires_at').notNull(),
    attempts: integer('attempts').notNull().default(0),
    createdAt: integer('created_at').notNull().default(0),
    /** Emails sent inside the current rolling daily window. */
    dailyCount: integer('daily_count').notNull().default(0),
    /** Start (unix sec) of the rolling 24h daily window. */
    windowStartedAt: integer('window_started_at').notNull().default(0),
  },
  (table) => ({
    expiryIdx: index('idx_email_codes_expiry').on(table.expiresAt),
  }),
);

export const messageDeliveries = sqliteTable(
  'message_deliveries',
  {
    id: text('id').primaryKey(),
    messageId: text('message_id')
      .notNull()
      .references(() => messages.id, { onDelete: 'cascade' }),
    // Recipient device that owns this ciphertext (NULL = legacy account-level row).
    recipientDeviceId: integer('recipient_device_id').references(() => devices.id, {
      onDelete: 'cascade',
    }),
    // Attributing sender device; degrades to NULL if that device is revoked.
    senderDeviceId: integer('sender_device_id').references(() => devices.id, {
      onDelete: 'set null',
    }),
    payload: text('payload'),
    messageType: text('message_type').notNull().default('signal'),
    deliveredAt: integer('delivered_at'),
    readAt: integer('read_at'),
  },
  (table) => ({
    deviceMessageIdx: index('idx_deliveries_device_message').on(
      table.recipientDeviceId,
      table.messageId,
    ),
    messageIdx: index('idx_deliveries_message').on(table.messageId),
    senderDeviceIdx: index('idx_deliveries_sender_device').on(table.senderDeviceId),
  }),
);

export const conversationUserSettings = sqliteTable(
  'conversation_user_settings',
  {
    id: text('id').primaryKey(),
    conversationId: text('conversation_id').notNull().references(() => conversations.id),
    userId: text('user_id').notNull().references(() => users.id),
    isPinned: integer('is_pinned').notNull().default(0),
    isMuted: integer('is_muted').notNull().default(0),
    isRestricted: integer('is_restricted').notNull().default(0),
    createdAt: integer('created_at').notNull().default(0),
    updatedAt: integer('updated_at').notNull().default(0),
  },
  (table) => ({
    userIdIdx: index('idx_conv_user_settings_user').on(table.userId),
    convUserIdx: index('idx_conv_user_settings_conv_user').on(table.conversationId, table.userId),
  }),
);

export const userBlocks = sqliteTable(
  'user_blocks',
  {
    id: text('id').primaryKey(),
    blockerId: text('blocker_id').notNull().references(() => users.id),
    blockedId: text('blocked_id').notNull().references(() => users.id),
    createdAt: integer('created_at').notNull().default(0),
  },
  (table) => ({
    blockerIdIdx: index('idx_user_blocks_blocker').on(table.blockerId),
    blockedIdIdx: index('idx_user_blocks_blocked').on(table.blockedId),
  }),
);

export const SCHEMA_SQL = `
-- generated via drizzle schema for documentation; see /worker/src/database/schema.ts
`;

