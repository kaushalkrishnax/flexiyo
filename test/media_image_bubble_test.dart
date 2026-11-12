import 'dart:typed_data';

import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/services/media/media_service.dart';
import 'package:flexiyo/storage/secure_keys.dart';
import 'package:flexiyo/widgets/media/media_image_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeMediaService extends MediaService {
  _FakeMediaService() : super(SecureKeys.instance);

  int fetchCalls = 0;
  int cachedCalls = 0;

  @override
  Future<Uint8List?> cachedBytes(MediaRef ref) async {
    cachedCalls += 1;
    return null;
  }

  @override
  Future<Uint8List> fetchAndDecrypt(
    MediaRef ref, {
    bool useCache = true,
    bool storeCache = true,
  }) async {
    fetchCalls += 1;
    return Uint8List.fromList(const [1, 2, 3]);
  }
}

MediaRef _mediaRef(ViewPolicy policy) {
  return MediaRef(
    id: 'media-1',
    kind: MediaKind.image,
    policy: policy,
    key: Uint8List.fromList(List<int>.filled(32, 1)),
    nonce: Uint8List.fromList(List<int>.filled(12, 2)),
    mac: Uint8List.fromList(List<int>.filled(16, 3)),
    mimeType: 'image/jpeg',
  );
}

Message _mediaMessage(ViewPolicy policy, {String senderId = 'them'}) {
  return Message(
    id: 'm1',
    conversationId: 'conversation-1',
    senderId: senderId,
    messageType: MessageType.signal,
    version: 1,
    createdAt: DateTime(2026, 1, 1, 12),
    status: MessageStatus.sent,
    decryptedText: _mediaRef(policy).toEnvelopeString(),
  );
}

Future<void> _pump(
  WidgetTester tester,
  Message message, {
  required bool isMine,
  required _FakeMediaService media,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [mediaServiceProvider.overrideWithValue(media)],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: MediaImageBubble(message: message, isMine: isMine),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('recipient view-limited media stays locked and is not fetched',
      (tester) async {
    final media = _FakeMediaService();
    await _pump(
      tester,
      _mediaMessage(ViewPolicy.once),
      isMine: false,
      media: media,
    );

    expect(find.text('Tap to view'), findsOneWidget);
    expect(find.text('View once'), findsOneWidget);
    expect(media.fetchCalls, 0);
    expect(media.cachedCalls, 0);
  });

  testWidgets('unlimited media loads lazily when visible', (tester) async {
    final media = _FakeMediaService();
    await _pump(
      tester,
      _mediaMessage(ViewPolicy.unlimited),
      isMine: false,
      media: media,
    );
    await tester.pumpAndSettle();

    expect(find.text('Tap to view'), findsNothing);
    expect(media.cachedCalls, greaterThan(0));
    expect(media.fetchCalls, 1);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('own view-limited media is not treated as locked', (tester) async {
    final media = _FakeMediaService();
    await _pump(
      tester,
      _mediaMessage(ViewPolicy.once, senderId: 'me'),
      isMine: true,
      media: media,
    );
    await tester.pumpAndSettle();

    expect(find.text('Tap to view'), findsNothing);
    expect(media.fetchCalls, 1);
  });
}
