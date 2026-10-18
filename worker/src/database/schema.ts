import { index, integer, sqliteTable, text } from 'drizzle-orm/sqlite-core';

// Drizzle is used only by the auth and user-search routes. All other Worker
// routes use D1 prepared statements against worker/migrations/*.sql.
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
    userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
    expiresAt: integer('expires_at').notNull(),
  },
  (table) => ({
    expiresIdx: index('idx_token_revocations_expires').on(table.expiresAt),
    userIdx: index('idx_token_revocations_user').on(table.userId),
  }),
);
