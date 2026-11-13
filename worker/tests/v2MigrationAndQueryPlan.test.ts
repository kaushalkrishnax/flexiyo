import { env, runInDurableObject } from 'cloudflare:test';
import type { D1Migration } from '@cloudflare/vitest-pool-workers/config';
import { beforeEach, describe, expect, it } from 'vitest';
import { conversationListQuery } from '../src/services/conversationList.js';
import { db, resetDatabase, roomStub } from './support.js';

interface ExplainRow {
  id: number;
  parent: number;
  notused: number;
  detail: string;
}

const CONVERSATION_DETAIL_SQL = `
  SELECT
    c.id,
    c.disappearing_timer,
    c.request_status,
    c.initiated_by_id,
    c.last_message_at,
    c.last_message_sender_id,
    c.created_at,
    COALESCE(cus.unread_count, 0) AS unread_count,
    cus.peer_seen_at,
    u.id AS conversant_id,
    u.username AS conversant_username
  FROM conversations c
  JOIN users u
    ON u.id = CASE WHEN c.user_a_id = ? THEN c.user_b_id ELSE c.user_a_id END
  LEFT JOIN conversation_user_state cus
    ON cus.conversation_id = c.id AND cus.user_id = ?
  WHERE c.id = ? AND (c.user_a_id = ? OR c.user_b_id = ?)`;

describe('V2-only schema, EXPLAIN QUERY PLAN, and 0014 migration', () => {
  beforeEach(async () => {
    await resetDatabase();
  });

  it('drops obsolete V1 tables, columns, and indexes and adds incremental state', async () => {
    const tables = await db
      .prepare(`SELECT name FROM sqlite_master WHERE type = 'table'`)
      .all<{ name: string }>();
    const tableNames = (tables.results ?? []).map((row) => row.name);
    expect(tableNames).not.toContain('message_deliveries');
    expect(tableNames).not.toContain('pre_keys');
    expect(tableNames).toContain('conversation_user_state');

    const [msgCols, deviceCols, convCols, indexes] = await Promise.all([
      db.prepare(`PRAGMA table_info(messages)`).all<{ name: string }>(),
      db.prepare(`PRAGMA table_info(devices)`).all<{ name: string }>(),
      db.prepare(`PRAGMA table_info(conversations)`).all<{ name: string }>(),
      db.prepare(`SELECT name FROM sqlite_master WHERE type = 'index'`).all<{ name: string }>(),
    ]);

    const msgColNames = (msgCols.results ?? []).map((c) => c.name);
    expect(msgColNames).not.toContain('encryption_version');

    const deviceColNames = (deviceCols.results ?? []).map((c) => c.name);
    for (const legacyCol of [
      'legacy_device_id',
      'registration_id',
      'identity_key',
      'signed_pre_key_id',
      'signed_pre_key_public',
      'signed_pre_key_signature',
      'encryption_version',
    ]) {
      expect(deviceColNames).not.toContain(legacyCol);
    }

    const convColNames = (convCols.results ?? []).map((c) => c.name);
    expect(convColNames).toContain('last_message_sender_id');

    const indexNames = (indexes.results ?? []).map((i) => i.name);
    expect(indexNames).toContain('idx_conversation_user_state_user');
    expect(indexNames).toContain('idx_messages_conv_sender_read');
    for (const obsoleteIndex of [
      'idx_messages_conv_version_created',
      'idx_messages_conv_unread',
      'idx_messages_conv_unsent',
      'idx_messages_conv_v1_active_sender',
      'idx_messages_conv_v2_sender_read',
    ]) {
      expect(indexNames).not.toContain(obsoleteIndex);
    }
  });

  it('executes inbox, requests, blocked, all, and detail queries without scanning messages', async () => {
    const userId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    for (const scope of ['inbox', 'requests', 'blocked', 'all'] as const) {
      const { sql, binds } = conversationListQuery(userId, scope);
      const plan = await db.prepare(`EXPLAIN QUERY PLAN ${sql}`).bind(...binds).all<ExplainRow>();
      const details = (plan.results ?? []).map((r) => r.detail);
      const joined = details.join('\n');

      expect(joined).not.toMatch(/\b(messages|message_deliveries|pre_keys)\b/);
      expect(joined).toContain('idx_conversation_user_state_user');
      expect(joined).not.toMatch(/\bSCAN\b/);
    }

    const detailPlan = await db
      .prepare(`EXPLAIN QUERY PLAN ${CONVERSATION_DETAIL_SQL}`)
      .bind(userId, userId, 'conv-1', userId, userId)
      .all<ExplainRow>();
    const detailJoined = (detailPlan.results ?? []).map((r) => r.detail).join('\n');
    expect(detailJoined).not.toMatch(/\b(messages|message_deliveries|pre_keys)\b/);
    expect(detailJoined).not.toMatch(/\bSCAN\b/);
  });

  it('migrates mixed V1+V2 data via 0014, deletes V1 rows, and backfills conversation_user_state', async () => {
    const migrations = (env as unknown as { TEST_MIGRATIONS: D1Migration[] }).TEST_MIGRATIONS;
    const pre0014 = migrations.filter((m) => !m.name.startsWith('0014_'));
    const migration0014 = migrations.find((m) => m.name.startsWith('0014_'));
    expect(migration0014).toBeDefined();

    const result = await runInDurableObject(roomStub('migration-sim'), async (_instance, state) => {
      const runMigrationQueries = (queries: string[]) => {
        for (const q of queries) {
          const trimmed = q.trim();
          if (!trimmed || /^PRAGMA\b/i.test(trimmed)) continue;
          state.storage.sql.exec(trimmed);
        }
      };

      for (const m of pre0014) {
        runMigrationQueries(m.queries);
      }

      const alice = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const bob = 'bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb';
      const carol = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

      state.storage.sql.exec(
        `INSERT INTO users (id, username, password_hash, created_at) VALUES (?, 'alice', 'x', 0), (?, 'bob', 'x', 0), (?, 'carol', 'x', 0)`,
        alice,
        bob,
        carol,
      );

      // Device 1: V1-only; Device 2 & 3: V2 active.
      state.storage.sql.exec(
        `INSERT INTO devices (id, user_id, installation_id, legacy_device_id, registration_id, identity_key, signed_pre_key_id, signed_pre_key_public, signed_pre_key_signature, status, created_at, encryption_version, identity_public_key)
         VALUES
           (1, ?, 'install-v1', 1, 111, 'ik', 1, 'spk', 'sig', 'active', 0, 1, NULL),
           (2, ?, 'install-v2-alice', 0, 0, '', 0, '', '', 'active', 0, 2, 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='),
           (3, ?, 'install-v2-bob', 0, 0, '', 0, '', '', 'active', 0, 2, 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=')`,
        alice,
        alice,
        bob,
      );
      state.storage.sql.exec(
        `INSERT INTO pre_keys (id, device_id, key_id, public_key) VALUES (1, 1, 1, 'pk')`,
      );

      // Conv1: mixed V1 + V2 messages (read + unread + unsent). Conv2: V1-only messages.
      state.storage.sql.exec(
        `INSERT INTO conversations (id, user_a_id, user_b_id, request_status, created_at, last_message_at, key_epoch)
         VALUES
           ('conv-mixed', ?, ?, 'accepted', 0, 999, 1),
           ('conv-v1-only', ?, ?, 'accepted', 0, 50, 0)`,
        alice,
        bob,
        alice,
        carol,
      );

      state.storage.sql.exec(
        `INSERT INTO conversation_key_epochs (conversation_id, epoch, created_by_device_id, created_at)
         VALUES ('conv-mixed', 1, 2, 0)`,
      );

      // Messages in conv-mixed:
      // - m-v1-old (v1, unread for alice, from bob) -> deleted by 0014
      // - m-v2-read (v2, alice -> bob, read_at = 200) -> preserved, counts toward bob.last_read_at=200 & alice.peer_seen_at=200
      // - m-v2-unread-1 (v2, bob -> alice, unread) -> preserved, unread for alice = 2
      // - m-v2-unread-2 (v2, bob -> alice, unread, created_at = 400) -> latest!
      // - m-v2-unsent (v2, bob -> alice, is_unsent = 1, created_at = 500) -> ignored in unread and last_message
      state.storage.sql.exec(
        `INSERT INTO messages (id, conversation_id, sender_id, sender_device_id, encryption_version, ciphertext, nonce, auth_tag, key_epoch, message_type, version, is_unsent, created_at, delivered_at, read_at)
         VALUES
           ('m-v1-old', 'conv-mixed', ?, 1, 1, NULL, NULL, NULL, NULL, 'signal', 1, 0, 100, NULL, NULL),
           ('m-v2-read', 'conv-mixed', ?, 2, 2, 'YWJj', 'n', 't', 1, 'signal', 1, 0, 200, 200, 200),
           ('m-v2-unread-1', 'conv-mixed', ?, 3, 2, 'YWJj', 'n', 't', 1, 'signal', 1, 0, 300, NULL, NULL),
           ('m-v2-unread-2', 'conv-mixed', ?, 3, 2, 'YWJj', 'n', 't', 1, 'signal', 1, 0, 400, NULL, NULL),
           ('m-v2-unsent', 'conv-mixed', ?, 3, 2, 'YWJj', 'n', 't', 1, 'signal', 1, 1, 500, NULL, NULL),
           ('m-v1-only', 'conv-v1-only', ?, 1, 1, NULL, NULL, NULL, NULL, 'signal', 1, 0, 50, NULL, NULL)`,
        bob,
        alice,
        bob,
        bob,
        bob,
        carol,
      );

      state.storage.sql.exec(
        `INSERT INTO message_deliveries (id, message_id, recipient_device_id, payload, message_type)
         VALUES ('d1', 'm-v1-old', 1, 'payload', 'signal')`,
      );

      runMigrationQueries(migration0014!.queries);

      const remainingTables = [...state.storage.sql.exec(`SELECT name FROM sqlite_master WHERE type = 'table'`)].map(
        (r) => String(r.name),
      );
      const remainingDeviceIds = [...state.storage.sql.exec(`SELECT id FROM devices ORDER BY id`)].map((r) =>
        Number(r.id),
      );
      const remainingMessageIds = [...state.storage.sql.exec(`SELECT id FROM messages ORDER BY created_at`)].map(
        (r) => String(r.id),
      );
      const convRows = [...state.storage.sql.exec(
        `SELECT id, last_message_at, last_message_sender_id FROM conversations ORDER BY id`,
      )];
      const stateRows = [...state.storage.sql.exec(
        `SELECT conversation_id, user_id, unread_count, last_read_at, peer_seen_at
         FROM conversation_user_state
         ORDER BY conversation_id, user_id`,
      )];

      return {
        remainingTables,
        remainingDeviceIds,
        remainingMessageIds,
        convRows,
        stateRows,
      };
    });

    expect(result.remainingTables).not.toContain('message_deliveries');
    expect(result.remainingTables).not.toContain('pre_keys');
    expect(result.remainingTables).toContain('conversation_user_state');
    expect(result.remainingDeviceIds).toEqual([2, 3]);
    expect(result.remainingMessageIds).toEqual([
      'm-v2-read',
      'm-v2-unread-1',
      'm-v2-unread-2',
      'm-v2-unsent',
    ]);
    expect(result.convRows).toEqual([
      {
        id: 'conv-mixed',
        last_message_at: 400,
        last_message_sender_id: 'bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb',
      },
      {
        id: 'conv-v1-only',
        last_message_at: null,
        last_message_sender_id: null,
      },
    ]);
    expect(result.stateRows).toEqual([
      {
        conversation_id: 'conv-mixed',
        user_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        unread_count: 2,
        last_read_at: null,
        peer_seen_at: 200,
      },
      {
        conversation_id: 'conv-mixed',
        user_id: 'bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb',
        unread_count: 0,
        last_read_at: 200,
        peer_seen_at: null,
      },
      {
        conversation_id: 'conv-v1-only',
        user_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        unread_count: 0,
        last_read_at: null,
        peer_seen_at: null,
      },
      {
        conversation_id: 'conv-v1-only',
        user_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        unread_count: 0,
        last_read_at: null,
        peer_seen_at: null,
      },
    ]);
  });
});
