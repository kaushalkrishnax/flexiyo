import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class LocalDb {
  LocalDb._();

  static final LocalDb instance = LocalDb._();

  Database? _db;

  Future<Database> get db async {
    final current = _db;
    if (current != null) return current;

    final directory = await getApplicationDocumentsDirectory();
    final path = p.join(directory.path, 'flexiyo.db');

    final database = await openDatabase(
      path,
      version: 2,
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
        reply_to_id TEXT
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
  }

  // Messages helpers

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
    final String where = beforeCreatedAt != null
        ? 'conversation_id = ? AND is_locally_deleted = 0 AND created_at < ?'
        : 'conversation_id = ? AND is_locally_deleted = 0';
    final List<Object?> args = beforeCreatedAt != null
        ? [conversationId, beforeCreatedAt]
        : [conversationId];

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

  Future<void> markUnsent(String messageId) async {
    final database = await db;
    await database.update(
      'messages',
      {'is_unsent': 1, 'encrypted_payload': null},
      where: 'id = ?',
      whereArgs: [messageId],
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

  // Conversations helpers

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

  Future<List<Map<String, dynamic>>> getAllConversations() async {
    final database = await db;
    return database.query(
      'conversations',
      orderBy: 'last_message_at DESC NULLS LAST, created_at DESC',
    );
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
}
