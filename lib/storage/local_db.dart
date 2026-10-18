import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

class LocalDb {
  LocalDb._();

  static final LocalDb instance = LocalDb._();

  Database? _db;

  /// Overrides the on-disk path so tests can run against a temp database.
  @visibleForTesting
  String? debugDatabasePath;

  /// Closes the cached handle so tests can reopen a different database.
  @visibleForTesting
  Future<void> resetForTesting() async {
    final database = _db;
    _db = null;
    if (database != null) await database.close();
  }

  Future<Database> get db async {
    final current = _db;
    if (current != null) return current;

    final String path;
    final overridePath = debugDatabasePath;
    if (overridePath != null) {
      path = overridePath;
    } else if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
      path = 'flexiyo.db';
    } else {
      final directory = await getApplicationDocumentsDirectory();
      path = p.join(directory.path, 'flexiyo.db');
    }

    final database = await openDatabase(
      path,
      version: 8,
      onCreate: _createSchema,
      onUpgrade: _onUpgrade,
    );

    _db = database;
    return database;
  }

  Future<void> initialize() async {
    await db;
  }

  Future<void> _createSchema(Database database, int version) async {
    await database.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        sender_device_id INTEGER,
        encrypted_payload TEXT,
        decrypted_text TEXT,
        message_type TEXT NOT NULL DEFAULT 'signal',
        version INTEGER NOT NULL DEFAULT 1,
        is_unsent INTEGER NOT NULL DEFAULT 0,
        is_locally_deleted INTEGER NOT NULL DEFAULT 0,
        is_edited INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        expires_at INTEGER,
        edited_at INTEGER,
        status TEXT NOT NULL DEFAULT 'sent',
        reply_to_id TEXT,
        reaction TEXT,
        read_at INTEGER
      );
    ''');

    await database.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        other_user_id TEXT NOT NULL,
        other_username TEXT NOT NULL,
        disappearing_timer INTEGER NOT NULL DEFAULT 0,
        last_message_at INTEGER,
        last_message_preview TEXT,
        unread_count INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      );
    ''');

    await database.execute('''
      CREATE TABLE conversation_settings (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        is_restricted INTEGER NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        is_muted INTEGER NOT NULL DEFAULT 0,
        is_pinned INTEGER NOT NULL DEFAULT 0
      );
    ''');
    await database.execute(
      'CREATE UNIQUE INDEX idx_conversation_settings_conversation ON conversation_settings(conversation_id);',
    );

    await database.execute('''
      CREATE TABLE signal_sessions (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        data TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
  }

  Future<void> _onUpgrade(
      Database database, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      try {
        await database.execute(
          'ALTER TABLE messages ADD COLUMN decrypted_text TEXT;',
        );
      } catch (_) {
        // Column may already exist
      }
    }
    if (oldVersion < 3) {
      try {
        await database.execute(
          'ALTER TABLE conversations ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0;',
        );
      } catch (_) {}
      try {
        await database.execute(
          'ALTER TABLE conversations ADD COLUMN is_muted INTEGER NOT NULL DEFAULT 0;',
        );
      } catch (_) {}
      try {
        await database.execute(
          'ALTER TABLE conversations ADD COLUMN is_restricted INTEGER NOT NULL DEFAULT 0;',
        );
      } catch (_) {}
    }
    if (oldVersion < 4) {
      try {
        await database.execute(
          'ALTER TABLE messages ADD COLUMN reaction TEXT;',
        );
      } catch (_) {}
    }
    if (oldVersion < 5) {
      // conversation_settings takes over per-user flags; carry any existing ones over,
      // then drop the flag columns from conversations (schema rebuild —
      // SQLite DROP COLUMN is not available across all bundled engines).
      await database.execute('''
        CREATE TABLE IF NOT EXISTS conversation_settings (
          id TEXT PRIMARY KEY,
          conversation_id TEXT NOT NULL,
          is_restricted INTEGER NOT NULL DEFAULT 0,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          is_muted INTEGER NOT NULL DEFAULT 0,
          is_pinned INTEGER NOT NULL DEFAULT 0
        );
      ''');
      try {
        await database.execute('''
          INSERT OR IGNORE INTO conversation_settings (id, conversation_id, is_restricted, is_muted, is_pinned)
          SELECT conversation_id, conversation_id, is_restricted, is_muted, is_pinned
          FROM conversations;
        ''');
        await database.execute(
          'CREATE UNIQUE INDEX IF NOT EXISTS idx_conversation_settings_conversation ON conversation_settings(conversation_id);',
        );
        await database
            .execute('ALTER TABLE conversations RENAME TO conversations_old;');
        await database.execute('''
          CREATE TABLE conversations (
            id TEXT PRIMARY KEY,
            other_user_id TEXT NOT NULL,
            other_username TEXT NOT NULL,
            disappearing_timer INTEGER NOT NULL DEFAULT 0,
            last_message_at INTEGER,
            last_message_preview TEXT,
            unread_count INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
          );
        ''');
        await database.execute('''
          INSERT INTO conversations
            (id, other_user_id, other_username, disappearing_timer, last_message_at,
             last_message_preview, unread_count, created_at)
          SELECT id, other_user_id, other_username, disappearing_timer, last_message_at,
             last_message_preview, unread_count, created_at
          FROM conversations_old;
        ''');
        await database.execute('DROP TABLE conversations_old;');
      } catch (_) {
        // Fresh installs or old upgrades already on the new layout.
      }
    }
    if (oldVersion < 6) {
      try {
        await database.execute(
          'ALTER TABLE messages ADD COLUMN read_at INTEGER;',
        );
      } catch (_) {}
    }
    if (oldVersion < 7) {
      await database.delete('messages', where: 'is_unsent = 1');
      await database.update(
        'conversations',
        {'last_message_preview': null},
        where: 'last_message_preview = ?',
        whereArgs: ['Message unsent'],
      );
    }
    if (oldVersion < 8) {
      try {
        await database.execute(
          'ALTER TABLE messages ADD COLUMN sender_device_id INTEGER;',
        );
      } catch (_) {}
    }
  }

  Future<void> upsertMessage(Map<String, dynamic> row) async {
    final database = await db;
    await database.insert(
      'messages',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getMessages(
    String conversationId, {
    int limit = 60,
    int? beforeCreatedAt,
  }) async {
    final database = await db;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final String where = beforeCreatedAt != null
        ? 'conversation_id = ? AND is_locally_deleted = 0 AND is_unsent = 0 '
            "AND message_type != 'system' "
            'AND (expires_at IS NULL OR expires_at > ?) AND created_at < ?'
        : 'conversation_id = ? AND is_locally_deleted = 0 AND is_unsent = 0 '
            "AND message_type != 'system' "
            'AND (expires_at IS NULL OR expires_at > ?)';
    final List<Object?> args = beforeCreatedAt != null
        ? [conversationId, nowMs, beforeCreatedAt]
        : [conversationId, nowMs];

    return database.query(
      'messages',
      where: where,
      whereArgs: args,
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  Future<void> markLocallyDeleted(String messageId) async {
    final database = await db;
    await database.update(
      'messages',
      {
        'is_locally_deleted': 1,
        'encrypted_payload': null,
        'decrypted_text': null,
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> deleteMessage(String messageId) async {
    final database = await db;
    await database.delete('messages', where: 'id = ?', whereArgs: [messageId]);
  }

  /// Removes messages whose read-based disappearing timer has elapsed.
  Future<void> purgeExpiredMessages(String conversationId) async {
    final database = await db;
    await database.delete(
      'messages',
      where:
          'conversation_id = ? AND expires_at IS NOT NULL AND expires_at <= ?',
      whereArgs: [conversationId, DateTime.now().millisecondsSinceEpoch],
    );
  }

  Future<void> clearMessageExpiries(String conversationId) async {
    final database = await db;
    await database.update(
      'messages',
      {'expires_at': null},
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
  }

  Future<void> updateMessageEdited(
    String messageId, {
    required String encryptedPayload,
    required int version,
    required int editedAt,
  }) async {
    final database = await db;
    await database.update(
      'messages',
      {
        'encrypted_payload': encryptedPayload,
        'version': version,
        'edited_at': editedAt,
        'is_edited': 1,
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> updateMessageReaction(String messageId, String? reaction) async {
    final database = await db;
    await database.update(
      'messages',
      {'reaction': reaction},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> upsertConversation(Map<String, dynamic> row) async {
    final database = await db;
    await database.insert(
      'conversations',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteConversation(String conversationId) async {
    final database = await db;
    await database.delete(
      'conversations',
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  /// Removes every trace of a conversation from the device and returns the
  /// affected message ids so callers can also purge plaintext caches. The
  /// re-seeds never resurrect the chat.
  Future<List<String>> deleteConversationData(String conversationId) async {
    final database = await db;
    final messageIds = (await database.query(
      'messages',
      columns: ['id'],
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    ))
        .map((row) => row['id'] as String)
        .toList();

    await database.transaction((txn) async {
      await txn.delete(
        'messages',
        where: 'conversation_id = ?',
        whereArgs: [conversationId],
      );
      await txn.delete(
        'conversations',
        where: 'id = ?',
        whereArgs: [conversationId],
      );
    });
    return messageIds;
  }

  /// Rows without any flag set are dropped so the table stays small.
  Future<void> applyChatState(
    String conversationId, {
    bool? isRestricted,
    bool? isDeleted,
    bool? isMuted,
    bool? isPinned,
  }) async {
    final database = await db;
    final existing = await database.query(
      'conversation_settings',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      limit: 1,
    );

    bool flag(String key) =>
        existing.isNotEmpty && (existing.first[key] as int? ?? 0) == 1;

    final row = {
      'id': conversationId,
      'conversation_id': conversationId,
      'is_restricted': (isRestricted ?? flag('is_restricted')) ? 1 : 0,
      'is_deleted': (isDeleted ?? flag('is_deleted')) ? 1 : 0,
      'is_muted': (isMuted ?? flag('is_muted')) ? 1 : 0,
      'is_pinned': (isPinned ?? flag('is_pinned')) ? 1 : 0,
    };

    if (row['is_restricted'] == 0 &&
        row['is_deleted'] == 0 &&
        row['is_muted'] == 0 &&
        row['is_pinned'] == 0) {
      await database.delete(
        'conversation_settings',
        where: 'conversation_id = ?',
        whereArgs: [conversationId],
      );
      return;
    }

    await database.insert(
      'conversation_settings',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, Map<String, dynamic>>> getChatStates() async {
    final database = await db;
    final rows = await database.query('conversation_settings');
    return {
      for (final row in rows) row['conversation_id'] as String: row,
    };
  }

  /// rows are filtered out.
  Future<List<Map<String, dynamic>>> getAllConversations() async {
    final database = await db;
    return database.rawQuery('''
      SELECT c.*
      FROM conversations c
      LEFT JOIN conversation_settings cs ON cs.conversation_id = c.id
      WHERE COALESCE(cs.is_deleted, 0) = 0
        AND COALESCE(cs.is_restricted, 0) = 0
      ORDER BY COALESCE(cs.is_pinned, 0) DESC, c.last_message_at DESC NULLS LAST, c.created_at DESC
    ''');
  }

  Future<List<Map<String, dynamic>>> getRestrictedConversations() async {
    final database = await db;
    return database.rawQuery('''
      SELECT c.*
      FROM conversations c
      JOIN conversation_settings cs ON cs.conversation_id = c.id
      WHERE cs.is_restricted = 1 AND cs.is_deleted = 0
      ORDER BY c.last_message_at DESC NULLS LAST, c.created_at DESC
    ''');
  }

  Future<List<Map<String, dynamic>>> getBlockedConversations() async {
    final database = await db;
    return database.rawQuery('''
      SELECT c.*
      FROM conversations c
      JOIN conversation_settings cs ON cs.conversation_id = c.id
      ORDER BY c.last_message_at DESC NULLS LAST, c.created_at DESC
    ''');
  }

  Future<void> updateConversationPreview(
    String conversationId, {
    required String preview,
    required int lastMessageAt,
    int unreadDelta = 0,
  }) async {
    final database = await db;
    final existing = await database.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [conversationId],
      limit: 1,
    );
    if (existing.isEmpty) return;

    final currentUnread = (existing.first['unread_count'] as int?) ?? 0;
    final newUnread = (currentUnread + unreadDelta).clamp(0, 9999);

    await database.update(
      'conversations',
      {
        'last_message_preview': preview,
        'last_message_at': lastMessageAt,
        'unread_count': newUnread,
      },
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  Future<void> clearUnreadCount(String conversationId) async {
    final database = await db;
    await database.update(
      'conversations',
      {'unread_count': 0},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  Future<void> clearAllUserData() async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete('messages');
      await txn.delete('conversations');
      await txn.delete('conversation_settings');
      await txn.delete('signal_sessions');
    });
  }
}
