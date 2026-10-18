import 'dart:io';

import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/storage/local_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Shaped exactly like a row hydrated from `GET /api/conversations/:id/messages`,
/// which always carries the sender's device id.
Message serverShapedMessage(String id) => Message(
      id: id,
      conversationId: 'conv-1',
      senderId: 'user-a',
      senderDeviceId: 3,
      encryptedPayload: 'c2lnbmFsLWNpcGhlcnRleHQ=',
      messageType: MessageType.signal,
      version: 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1792331831000),
      status: MessageStatus.sent,
    );

const _v7MessagesSchema = '''
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
    reply_to_id TEXT,
    reaction TEXT,
    read_at INTEGER
  );
''';

const _v7ConversationsSchema = '''
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
''';

const _v7ConversationSettingsSchema = '''
  CREATE TABLE conversation_settings (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    is_restricted INTEGER NOT NULL DEFAULT 0,
    is_deleted INTEGER NOT NULL DEFAULT 0,
    is_muted INTEGER NOT NULL DEFAULT 0,
    is_pinned INTEGER NOT NULL DEFAULT 0
  );
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('flexiyo_local_db_test');
  });

  tearDown(() async {
    await LocalDb.instance.resetForTesting();
    LocalDb.instance.debugDatabasePath = null;
  });

  test('server message rows persist and round-trip through the cache',
      () async {
    LocalDb.instance.debugDatabasePath = p.join(tempDir.path, 'fresh.db');
    await LocalDb.instance.initialize();

    await LocalDb.instance.upsertMessage(serverShapedMessage('m-1').toJson());

    final rows = await LocalDb.instance.getMessages('conv-1');
    expect(rows, hasLength(1));
    final restored = Message.fromDbJson(rows.single);
    expect(restored.senderDeviceId, 3);
    expect(restored.encryptedPayload, 'c2lnbmFsLWNpcGhlcnRleHQ=');
  });

  test('v7 databases gain sender_device_id on upgrade without losing rows',
      () async {
    final dbPath = p.join(tempDir.path, 'upgrade.db');
    final oldDb = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 7,
        onCreate: (db, version) async {
          await db.execute(_v7MessagesSchema);
          await db.execute(_v7ConversationsSchema);
          await db.execute(_v7ConversationSettingsSchema);
        },
      ),
    );
    await oldDb.insert('messages', {
      'id': 'm-old',
      'conversation_id': 'conv-1',
      'sender_id': 'user-b',
      'decrypted_text': 'kept across upgrade',
      'message_type': 'signal',
      'version': 1,
      'is_unsent': 0,
      'is_locally_deleted': 0,
      'is_edited': 0,
      'created_at': 1792331831000,
      'status': 'sent',
    });
    await oldDb.close();

    LocalDb.instance.debugDatabasePath = dbPath;
    await LocalDb.instance.initialize();

    final before = await LocalDb.instance.getMessages('conv-1');
    expect(before, hasLength(1));
    expect(before.single['decrypted_text'], 'kept across upgrade');

    await LocalDb.instance.upsertMessage(serverShapedMessage('m-new').toJson());

    final after = await LocalDb.instance.getMessages('conv-1');
    expect(after.map((row) => row['id']), containsAll(['m-old', 'm-new']));
    expect(
      after.firstWhere((row) => row['id'] == 'm-new')['sender_device_id'],
      3,
    );
  });
}
