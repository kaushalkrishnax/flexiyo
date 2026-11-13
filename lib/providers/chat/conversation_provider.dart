import 'dart:async';

import 'package:flexiyo/models/conversation.dart';
import 'package:flexiyo/models/message.dart';
import 'package:flutter/foundation.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/providers/chat/chat_provider.dart';
import 'package:flexiyo/providers/chat/conversation_pagination.dart';
import 'package:flexiyo/providers/conversation_crypto_provider.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/services/conversation_crypto_service.dart';
import 'package:flexiyo/services/media/media_service.dart';
import 'package:flexiyo/services/ws_service.dart';
import 'package:flexiyo/storage/local_db.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:uuid/uuid.dart';

class EditDraft {
  const EditDraft({required this.message, required this.text});
  final Message message;
  final String text;
}

class ConversationState {
  const ConversationState({
    this.conversation,
    this.messages = const [],
    this.isLoading = false,
    this.isLoadingOlderMessages = false,
    this.hasMoreMessages = true,
    this.newIncomingMessages = 0,
    this.isSending = false,
    this.error,
    this.isTyping = false,
    this.replyTo,
    this.editDraft,
    this.selectedMessageIds = const {},
    this.isSelectionMode = false,
  });

  final Conversation? conversation;
  final List<Message> messages;
  final bool isLoading;
  final bool isLoadingOlderMessages;
  final bool hasMoreMessages;
  final int newIncomingMessages;
  final bool isSending;
  final String? error;
  final bool isTyping;
  final Message? replyTo;
  final EditDraft? editDraft;
  final Set<String> selectedMessageIds;
  final bool isSelectionMode;

  ConversationState copyWith({
    Conversation? conversation,
    List<Message>? messages,
    bool? isLoading,
    bool? isLoadingOlderMessages,
    bool? hasMoreMessages,
    int? newIncomingMessages,
    bool? isSending,
    String? error,
    bool clearError = false,
    bool? isTyping,
    Message? replyTo,
    bool clearReplyTo = false,
    EditDraft? editDraft,
    bool clearEditDraft = false,
    Set<String>? selectedMessageIds,
    bool? isSelectionMode,
  }) {
    return ConversationState(
      conversation: conversation ?? this.conversation,
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      isLoadingOlderMessages:
          isLoadingOlderMessages ?? this.isLoadingOlderMessages,
      hasMoreMessages: hasMoreMessages ?? this.hasMoreMessages,
      newIncomingMessages: newIncomingMessages ?? this.newIncomingMessages,
      isSending: isSending ?? this.isSending,
      error: clearError ? null : (error ?? this.error),
      isTyping: isTyping ?? this.isTyping,
      replyTo: clearReplyTo ? null : (replyTo ?? this.replyTo),
      editDraft: clearEditDraft ? null : (editDraft ?? this.editDraft),
      selectedMessageIds: selectedMessageIds ?? this.selectedMessageIds,
      isSelectionMode: isSelectionMode ?? this.isSelectionMode,
    );
  }
}

class ConversationNotifier extends StateNotifier<ConversationState> {
  ConversationNotifier({
    required this.conversationId,
    required ApiService api,
    required String myUserId,
    required Ref ref,
  })  : _api = api,
        _myUserId = myUserId,
        _ref = ref,
        super(const ConversationState());

  final String conversationId;
  final ApiService _api;
  final String _myUserId;
  final Ref _ref;

  WsService? _ws;
  StreamSubscription<Map<String, dynamic>>? _wsSub;
  Timer? _typingTimer;
  Timer? _expiryTimer;
  bool _peerIsTyping = false;

  static const _uuid = Uuid();

  // Initialization

  Future<void> initialize() async {
    state = state.copyWith(isLoading: true, clearError: true);

    // Clearing the badge as soon as the chat opens keeps the inbox in sync
    // without waiting for the server round-trip below.
    _ref.read(chatsProvider.notifier).setActiveConversation(conversationId);

    final cachedConversation = _ref
        .read(chatsProvider)
        .conversations
        .where((conversation) => conversation.id == conversationId)
        .firstOrNull;
    if (cachedConversation != null) {
      state = state.copyWith(conversation: cachedConversation);
      if (cachedConversation.disappearingTimer == 0) {
        try {
          await LocalDb.instance.clearMessageExpiries(conversationId);
        } catch (_) {}
      }
    }

    // Drop stale local rows before they are rendered; the server has either
    // deleted them or marked them expired.
    try {
      await LocalDb.instance.purgeExpiredMessages(conversationId);
    } catch (_) {}

    var hasMoreMessages = false;

    // Load from local cache first for instant display
    try {
      final cachedRows = await LocalDb.instance.getMessages(conversationId, limit: 10);
      final cached = cachedRows.reversed.map(Message.fromDbJson).toList();
      if (cached.isNotEmpty) {
        state = state.copyWith(messages: cached);
        hasMoreMessages = hasOlderPage(fetched: cachedRows.length);
      }
    } catch (_) {}

    // Then load from server
    try {
      Conversation? conv;
      conv = state.conversation;
      if (conv == null) {
        try {
          conv = await _api.getConversation(conversationId);
        } catch (_) {
          final conversations = await _api.getConversations();
          conv = conversations.where((c) => c.id == conversationId).firstOrNull;
        }
      }
      if (conv == null) {
        throw Exception('Conversation not found');
      }

      final messages = await _api.getMessages(
        conversationId,
        limit: 10,
      )..sort(_compareMessages);
      hasMoreMessages = hasMoreMessages || hasOlderPage(fetched: messages.length);
      final crypto = _ref.read(conversationCryptoProvider);
      final cachedById = {
        for (final message in state.messages) message.id: message
      };
      final hydratedMessages = [...state.messages];

      for (final msg in messages) {
        Message hydrated;
        try {
          hydrated = await _hydrateFromServer(msg, crypto, cachedById);
        } catch (_) {
          // One bad row must never discard the rest of the batch.
          hydrated = msg;
        }

        final existingIndex =
            hydratedMessages.indexWhere((message) => message.id == msg.id);
        if (existingIndex == -1) {
          hydratedMessages.add(hydrated);
        } else {
          hydratedMessages[existingIndex] = hydrated;
        }
        await _cacheMessage(hydrated);
      }

      hydratedMessages.sort(_compareMessages);

      if (mounted) {
        state = state.copyWith(
          conversation: conv,
          messages: hydratedMessages,
          isLoading: false,
          hasMoreMessages: hasMoreMessages,
        );

        // Mark as read only if accepted
        _ref.read(chatsProvider.notifier).markRead(conversationId);
        _scheduleExpiryPurge();
        if (conv.requestStatus == 'accepted' && !(await _isRestricted())) {
          unawaited(_markConversationRead());
        }
      }
    } catch (e) {
      if (mounted) {
        state = state.copyWith(isLoading: false, error: e.toString());
      }
    }

    // Connect WebSocket
    await _connectWs();
  }

  Future<void> loadOlderMessages() async {
    final currentMessages = state.messages;
    if (!mounted ||
        state.isLoadingOlderMessages ||
        !state.hasMoreMessages ||
        currentMessages.isEmpty) {
      return;
    }

    final cursorMessage = currentMessages.first;
    state = state.copyWith(isLoadingOlderMessages: true);

    var localRows = <Map<String, dynamic>>[];
    var remoteMessages = <Message>[];
    var remoteFetchSucceeded = false;

    try {
      localRows = await LocalDb.instance.getMessages(
        conversationId,
        limit: 10,
        beforeMessageId: cursorMessage.id,
      );
    } catch (_) {}

    try {
      remoteMessages = await _api.getMessages(
        conversationId,
        limit: 10,
        before: cursorMessage.id,
        beforeCreatedAt: cursorMessage.createdAt,
      )..sort(_compareMessages);
      remoteFetchSucceeded = true;
    } catch (_) {}

    try {
      final olderById = <String, Message>{
        for (final row in localRows.reversed)
          (row['id'] as String): Message.fromDbJson(row),
      };
      final cachedById = <String, Message>{
        for (final message in state.messages) message.id: message,
        ...olderById,
      };

      final crypto = _ref.read(conversationCryptoProvider);

      for (final message in remoteMessages) {
        final hydrated = await _hydrateFromServer(
          message,
          crypto,
          cachedById,
        );
        olderById[message.id] = hydrated;
        await _cacheMessage(hydrated);
      }

      final merged = mergeOlderPage(
        older: olderById.values,
        current: state.messages,
      );

      if (mounted) {
        state = state.copyWith(
          messages: merged,
          hasMoreMessages: remoteFetchSucceeded
              ? hasOlderPage(fetched: remoteMessages.length) ||
                  hasOlderPage(fetched: localRows.length)
              : hasOlderPage(fetched: localRows.length) ||
                  state.hasMoreMessages,
          isLoadingOlderMessages: false,
        );
      }
    } catch (error) {
      if (mounted) {
        state = state.copyWith(
          isLoadingOlderMessages: false,
          error: error.toString(),
        );
      }
    }
  }

  Future<bool> _isRestricted() async {
    final states = await LocalDb.instance.getChatStates();
    final row = states[conversationId];
    return row != null && (row['is_restricted'] as int? ?? 0) == 1;
  }

  /// Best-effort local write; a failed cache row must never block rendering,
  /// delivery acks, or read receipts.
  Future<void> _cacheMessage(Message message) async {
    try {
      await LocalDb.instance.upsertMessage(message.toJson());
    } catch (_) {}
  }

  /// Resolves the renderable copy of a server row: locally cached plaintext
  /// when available, otherwise a fresh V2 decrypt.
  Future<Message> _hydrateFromServer(
    Message msg,
    ConversationCryptoService crypto,
    Map<String, Message> cachedById,
  ) async {
    if (msg.isUnsent) return msg;

    final cachedText = cachedById[msg.id]?.decryptedText;
    if (cachedText != null) return msg.copyWith(decryptedText: cachedText);

    if (msg.encryptedPayload == null ||
        msg.nonce == null ||
        msg.authTag == null ||
        msg.keyEpoch == null) {
      return msg;
    }
    try {
      final plaintext = await crypto.decryptMessage(
        userId: _myUserId,
        conversationId: msg.conversationId,
        messageId: msg.id,
        keyEpoch: msg.keyEpoch!,
        ciphertext: msg.encryptedPayload!,
        nonce: msg.nonce!,
        authTag: msg.authTag!,
      );
      return msg.copyWith(decryptedText: plaintext);
    } catch (_) {
      return msg;
    }
  }

  Future<void> _connectWs() async {
    try {
      final wsUrl = await _api.buildWsUrl(conversationId);
      String finalUrl = wsUrl;
      try {
        final crypto = _ref.read(conversationCryptoProvider);
        final deviceId = await crypto.ensureDeviceRegistered(userId: _myUserId);
        finalUrl = '$wsUrl&deviceId=$deviceId';
      } catch (_) {}
      _ws = WsService(conversationId: conversationId, wsUrl: finalUrl);
      _wsSub = _ws!.events.listen((event) => _handleWsEvent(event));
      await _ws!.connect();
    } catch (_) {
      debugPrint('[WS] conversation connection setup failed');
    }
  }

  void _handleWsEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    switch (type) {
      case 'new_message':
        unawaited(_onRemoteNewMessage(event));
      case 'message_edited':
        unawaited(_onRemoteMessageEdited(event));
      case 'message_deleted':
        _onRemoteMessageDeleted(event);
      case 'typing_start':
        _onPeerTypingStart();
      case 'typing_stop':
        _onPeerTypingStop();
      case 'request_accepted':
        unawaited(updateRequestStatus('accepted'));
      case 'request_rejected':
        unawaited(updateRequestStatus('rejected'));
      case 'message_delivered':
        _updateMessageStatus(
          event['messageId'] as String? ?? '',
          MessageStatus.delivered,
        );
      case 'messages_read':
        _onMessagesRead(event);
      case 'message_reaction':
        _onRemoteMessageReaction(event);
      case 'disappearing_timer_changed':
        _onDisappearingTimerChanged(event);
      default:
        break;
    }
  }

  Future<void> updateRequestStatus(String requestStatus) async {
    final current = state.conversation;
    if (current == null || current.requestStatus == requestStatus) return;
    final updated = current.copyWith(requestStatus: requestStatus);
    state = state.copyWith(conversation: updated);
    if (requestStatus == 'accepted') {
      await _ref.read(chatsProvider.notifier).upsertConversation(updated);
    } else if (requestStatus == 'rejected') {
      await _ref
          .read(chatsProvider.notifier)
          .removeConversation(conversationId);
    }
  }

  void updateConversation(Conversation conversation) {
    state = state.copyWith(conversation: conversation);
  }

  Future<void> _onRemoteNewMessage(Map<String, dynamic> event) async {
    final msgId = event['messageId'] as String?;
    if (msgId == null || state.messages.any((m) => m.id == msgId)) return;

    final senderId = event['senderId'] as String? ?? '';
    final encryptionVersion = (event['encryptionVersion'] as num?)?.toInt() ?? 2;
    if (encryptionVersion != 2) return;
    final senderDeviceId = (event['senderDeviceId'] as num?)?.toInt();
    final replyToId = event['replyToId'] as String?;
    final createdAtRaw = event['createdAt'];
    final expiresAtRaw = event['expiresAt'];

    DateTime createdAt = DateTime.now();
    if (createdAtRaw is int) {
      final timestamp = createdAtRaw > 1e12 ? createdAtRaw : createdAtRaw * 1000;
      createdAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    }
    DateTime? expiresAt;
    if (expiresAtRaw is int) {
      final timestamp = expiresAtRaw > 1e12 ? expiresAtRaw : expiresAtRaw * 1000;
      expiresAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    }

    final encryptedPayload = event['ciphertext'] as String?;
    final nonce = event['nonce'] as String?;
    final authTag = event['authTag'] as String?;
    final keyEpoch = (event['keyEpoch'] as num?)?.toInt();
    String? plaintext;

    if (encryptedPayload != null &&
        nonce != null &&
        authTag != null &&
        keyEpoch != null) {
      try {
        plaintext = await _ref.read(conversationCryptoProvider).decryptMessage(
          userId: _myUserId,
          conversationId: conversationId,
          messageId: msgId,
          keyEpoch: keyEpoch,
          ciphertext: encryptedPayload,
          nonce: nonce,
          authTag: authTag,
        );
      } catch (_) {
        plaintext = null;
      }
    }

    final message = Message(
      id: msgId,
      conversationId: conversationId,
      senderId: senderId,
      senderDeviceId: senderDeviceId,
      encryptedPayload: encryptedPayload,
      encryptionVersion: 2,
      nonce: nonce,
      authTag: authTag,
      keyEpoch: keyEpoch,
      decryptedText: plaintext,
      messageType: MessageType.signal,
      version: 1,
      createdAt: createdAt,
      expiresAt: expiresAt,
      status: MessageStatus.sent,
      replyToId: replyToId,
    );

    _upsertMessage(message);
    await _cacheMessage(message);
    _scheduleExpiryPurge();

    if (plaintext != null) _ws?.sendDeliveryAck(msgId);

    final isIncoming = senderId != _myUserId;

    if (isIncoming) {
      state = state.copyWith(newIncomingMessages: state.newIncomingMessages + 1);
    }

    final mediaPreview = plaintext != null ? MediaRef.parse(plaintext) : null;
    _ref.read(chatsProvider.notifier).onNewMessage(
      conversationId: conversationId,
      preview: mediaPreview?.label ?? (plaintext ?? 'Message'),
      lastMessageAt: createdAt,
      isIncoming: isIncoming,
    );
  }


  void _onDisappearingTimerChanged(Map<String, dynamic> event) {
    final timer = event['timer'];
    final current = state.conversation;
    if (timer is! int || current == null) return;
    if (timer == 0) {
      final cleared = state.messages
          .map((message) => message.copyWith(clearExpiresAt: true))
          .toList();
      state = state.copyWith(
        conversation: current.copyWith(disappearingTimer: timer),
        messages: cleared,
      );
      unawaited(LocalDb.instance.clearMessageExpiries(conversationId));
      _scheduleExpiryPurge();
      return;
    }
    state = state.copyWith(
      conversation: current.copyWith(disappearingTimer: timer),
    );
  }

  void _onMessagesRead(Map<String, dynamic> event) {
    if (event['readBy'] == _myUserId) return;
    final readAtRaw = event['readAt'];
    if (readAtRaw is! int) return;
    final readAtMs = readAtRaw > 1e12 ? readAtRaw : readAtRaw * 1000;
    final readAt = DateTime.fromMillisecondsSinceEpoch(readAtMs);
    final timer = state.conversation?.disappearingTimer ?? 0;
    final expiresAt = timer == -1
        ? readAt
        : timer > 0
            ? readAt.add(Duration(seconds: timer))
            : null;
    final updated = state.messages.map((message) {
      if (message.senderId == _myUserId &&
          message.createdAt.millisecondsSinceEpoch <= readAtMs) {
        return message.copyWith(
          status: MessageStatus.read,
          readAt: readAt,
          expiresAt: expiresAt,
        );
      }
      return message;
    }).toList();
    state = state.copyWith(messages: updated);
    for (final message in updated) {
      if (message.senderId == _myUserId &&
          message.readAt == readAt &&
          expiresAt != null) {
        unawaited(_cacheMessage(message));
      }
    }
    _purgeExpiredMessages();

    _ref.read(chatsProvider.notifier).markPeerSeen(conversationId, readAt);
  }

  void resetNewIncomingMessages() {
    if (state.newIncomingMessages == 0) return;
    state = state.copyWith(newIncomingMessages: 0);
  }

  Future<void> markLatestMessagesRead() async {
    if (state.conversation?.requestStatus != 'accepted' ||
        await _isRestricted()) {
      return;
    }
    await _markConversationRead();
  }

  Future<void> _markConversationRead() async {
    try {
      final result = await _api.markConversationRead(conversationId);
      final readAtRaw = result['readAt'];
      if (readAtRaw is! int) return;
      final timer = state.conversation?.disappearingTimer ?? 0;
      if (timer == 0) return;

      final readAtSeconds = readAtRaw > 1e12 ? readAtRaw ~/ 1000 : readAtRaw;
      final readAt = DateTime.fromMillisecondsSinceEpoch(readAtSeconds * 1000);
      final expiresAt =
          timer == -1 ? readAt : readAt.add(Duration(seconds: timer));
      final updated = state.messages.map((message) {
        if (message.senderId != _myUserId &&
            message.createdAt.millisecondsSinceEpoch <=
                readAt.millisecondsSinceEpoch &&
            message.expiresAt == null) {
          return message.copyWith(expiresAt: expiresAt);
        }
        return message;
      }).toList();
      state = state.copyWith(messages: updated);
      for (final message in updated) {
        if (message.senderId != _myUserId && message.expiresAt == expiresAt) {
          unawaited(_cacheMessage(message));
        }
      }
      _purgeExpiredMessages();
    } catch (_) {}
  }

  /// Schedules a local purge for the next message expiry so the chat stays
  /// clean without waiting for the server's cron pass.
  void _scheduleExpiryPurge() {
    _expiryTimer?.cancel();
    final now = DateTime.now();
    DateTime? next;
    for (final message in state.messages) {
      final expiresAt = message.expiresAt;
      if (expiresAt != null &&
          expiresAt.isAfter(now) &&
          (next == null || expiresAt.isBefore(next))) {
        next = expiresAt;
      }
    }
    if (next == null) return;
    _expiryTimer = Timer(next.difference(now), _purgeExpiredMessages);
  }

  void _purgeExpiredMessages() {
    _expiryTimer?.cancel();
    final now = DateTime.now();
    final expired = state.messages
        .where((message) =>
            message.expiresAt != null && !message.expiresAt!.isAfter(now))
        .toList();
    if (expired.isNotEmpty) {
      final expiredIds = expired.map((message) => message.id).toSet();
      state = state.copyWith(
        messages: state.messages
            .where((message) => !expiredIds.contains(message.id))
            .toList(),
        clearReplyTo: expiredIds.contains(state.replyTo?.id),
      );
      for (final message in expired) {
        unawaited(LocalDb.instance.deleteMessage(message.id));
        final mediaId = message.mediaRef?.id;
        if (mediaId != null) {
          unawaited(_ref.read(mediaServiceProvider).purgeLocal(mediaId));
        }
      }
    }
    _scheduleExpiryPurge();
  }

  Future<void> _onRemoteMessageEdited(Map<String, dynamic> event) async {
    final messageId = event['messageId'] as String?;
    if (messageId == null) return;
    final original = state.messages.where((message) => message.id == messageId).firstOrNull;
    if (original == null) return;

    final encryptionVersion =
        (event['encryptionVersion'] as num?)?.toInt() ?? original.encryptionVersion;
    if (encryptionVersion != 2) return;
    final version = (event['version'] as num?)?.toInt() ?? original.version;
    final editedAtRaw = event['editedAt'];
    final editedAt = editedAtRaw is int
        ? DateTime.fromMillisecondsSinceEpoch(
            editedAtRaw > 1e12 ? editedAtRaw : editedAtRaw * 1000,
          )
        : DateTime.now();

    final ciphertext = event['ciphertext'] as String?;
    final nonce = event['nonce'] as String?;
    final authTag = event['authTag'] as String?;
    final keyEpoch = (event['keyEpoch'] as num?)?.toInt();
    String? plaintext;

    if (ciphertext != null &&
        nonce != null &&
        authTag != null &&
        keyEpoch != null) {
      try {
        plaintext = await _ref.read(conversationCryptoProvider).decryptMessage(
          userId: _myUserId,
          conversationId: conversationId,
          messageId: messageId,
          keyEpoch: keyEpoch,
          ciphertext: ciphertext,
          nonce: nonce,
          authTag: authTag,
        );
      } catch (_) {
        plaintext = null;
      }
    }

    final updated = original.copyWith(
      encryptedPayload: ciphertext,
      encryptionVersion: 2,
      nonce: nonce,
      authTag: authTag,
      keyEpoch: keyEpoch,
      messageType: MessageType.signal,
      decryptedText: plaintext,
      version: version,
      isEdited: true,
      editedAt: editedAt,
      status: MessageStatus.sent,
    );
    _upsertMessage(updated);
    await _cacheMessage(updated);
  }


  void _onRemoteMessageDeleted(Map<String, dynamic> event) {
    final msgId = event['messageId'] as String?;
    if (msgId == null) return;
    final mediaId = state.messages
        .where((message) => message.id == msgId)
        .firstOrNull
        ?.mediaRef
        ?.id;

    state = state.copyWith(
      messages: state.messages.where((message) => message.id != msgId).toList(),
      clearReplyTo: state.replyTo?.id == msgId,
    );
    unawaited(LocalDb.instance.deleteMessage(msgId));
    if (mediaId != null) {
      unawaited(_ref.read(mediaServiceProvider).purgeLocal(mediaId));
    }
  }

  void _onRemoteMessageReaction(Map<String, dynamic> event) {
    final msgId = event['messageId'] as String?;
    if (msgId == null) return;
    final reaction = event['reaction'] as String? ?? event['emoji'] as String?;

    final updated = state.messages.map((m) {
      if (m.id == msgId) {
        return m.copyWith(reaction: reaction, clearReaction: reaction == null);
      }
      return m;
    }).toList();

    state = state.copyWith(messages: updated);
    LocalDb.instance.updateMessageReaction(msgId, reaction);
  }

  void _onPeerTypingStart() {
    _typingTimer?.cancel();
    if (!_peerIsTyping) {
      _peerIsTyping = true;
      if (mounted) state = state.copyWith(isTyping: true);
    }
    // Auto-clear after 4 s in case typing_stop is missed
    _typingTimer = Timer(const Duration(seconds: 4), _onPeerTypingStop);
  }

  void _onPeerTypingStop() {
    _typingTimer?.cancel();
    _peerIsTyping = false;
    if (mounted) state = state.copyWith(isTyping: false);
  }

  // User actions

  Future<void> sendMessage(String text, {String? messageId}) async {
    var conv = state.conversation;
    if (conv == null) {
      try {
        conv = await _api.getConversation(conversationId);
        if (mounted) state = state.copyWith(conversation: conv);
      } catch (_) {}
    }
    if (text.isEmpty || conv == null || state.isSending) return;
    if (await _isRestricted()) {
      if (mounted) state = state.copyWith(error: 'Unrestrict this chat to send messages');
      return;
    }
    if (conv.requestStatus == 'pending' && conv.initiatedById != _myUserId) return;
    if (conv.requestStatus == 'pending' &&
        state.messages.any((message) => !message.isUnsent && message.status != MessageStatus.failed)) {
      return;
    }

    final msgId = messageId ?? _uuid.v4();
    final now = DateTime.now();
    final replyToId = state.replyTo?.id;
    final optimistic = Message(
      id: msgId,
      conversationId: conversationId,
      senderId: _myUserId,
      decryptedText: text,
      messageType: MessageType.signal,
      version: 1,
      createdAt: now,
      status: MessageStatus.sending,
      replyToId: replyToId,
      encryptionVersion: 2,
    );

    _upsertMessage(optimistic);
    await _cacheMessage(optimistic);
    state = state.copyWith(clearReplyTo: true);
    final optimisticPreview = MediaRef.parse(text);
    _ref.read(chatsProvider.notifier).onNewMessage(
      conversationId: conversationId,
      preview: optimisticPreview?.label ?? text,
      lastMessageAt: now,
    );
    state = state.copyWith(isSending: true);

    try {
      final crypto = _ref.read(conversationCryptoProvider);
      final encrypted = await crypto.encryptMessage(
        conversationId: conversationId,
        messageId: msgId,
        myUserId: _myUserId,
        peerUserId: conv.otherUserId,
        plaintext: text,
      );
      final deviceId = await crypto.ensureDeviceRegistered(userId: _myUserId);
      if (_ws == null) await _connectWs();
      final ws = _ws;
      if (ws == null) throw StateError('WebSocket unavailable');
      await ws.ensureConnected();

      final ack = await ws.request({
        'type': 'send_message',
        'conversationId': conversationId,
        'id': msgId,
        'recipientId': conv.otherUserId,
        ...encrypted,
        'mediaId': MediaRef.parse(text)?.id,
        'replyToId': replyToId,
      });
      if (ack['ok'] != true && ack['type'] != 'ack') {
        final code = ack['code']?.toString() ?? 'send_rejected';
        if (code == 'key_rotation_required' ||
            code == 'key_epoch_conflict' ||
            code == 'conversation_keys_not_provisioned') {
          throw StateError('$code: reopen the conversation to synchronize encryption keys');
        }
        throw StateError(ack['message']?.toString() ?? code);
      }

      final sent = optimistic.copyWith(
        senderDeviceId: deviceId,
        encryptedPayload: encrypted['ciphertext'] as String,
        encryptionVersion: 2,
        nonce: encrypted['nonce'] as String,
        authTag: encrypted['authTag'] as String,
        keyEpoch: encrypted['keyEpoch'] as int,
        status: MessageStatus.sent,
      );
      _upsertMessage(sent);
      await _cacheMessage(sent);
    } catch (error, stackTrace) {
      debugPrint('[SEND] failed: $error\n$stackTrace');
      _updateMessageStatus(msgId, MessageStatus.failed);
      if (mounted) state = state.copyWith(error: 'Send failed: $error');
    } finally {
      if (mounted) state = state.copyWith(isSending: false);
    }
  }


  Future<void> retryFailedMessage(String messageId) async {
    final msg = state.messages.firstWhere(
      (m) => m.id == messageId,
      orElse: () => throw StateError('Message not found'),
    );
    if (msg.senderId != _myUserId || msg.status != MessageStatus.failed) return;
    final text = msg.decryptedText;
    if (text == null || text.isEmpty) return;

    // Remove the failed optimistic message and re-send
    state = state.copyWith(
      messages: state.messages.where((m) => m.id != messageId).toList(),
      clearError: true,
    );
    // Retry with the same message UUID so the server treats it as an
    // idempotent retry rather than a new message.
    await sendMessage(text, messageId: messageId);
  }

  Future<void> editMessage(String messageId, String newText) async {
    final original = state.messages.firstWhere(
      (message) => message.id == messageId,
      orElse: () => throw StateError('Message not found'),
    );
    if (original.senderId != _myUserId || !original.isEditEligible) return;

    final conversation = state.conversation;
    if (conversation == null) return;
    final now = DateTime.now();

    try {
      final crypto = _ref.read(conversationCryptoProvider);
      final encrypted = await crypto.encryptMessage(
        conversationId: conversationId,
        messageId: messageId,
        myUserId: _myUserId,
        peerUserId: conversation.otherUserId,
        plaintext: newText,
      );
      final deviceId = await crypto.ensureDeviceRegistered(userId: _myUserId);
      final updated = original.copyWith(
        decryptedText: newText,
        senderDeviceId: deviceId,
        encryptedPayload: encrypted['ciphertext'] as String,
        encryptionVersion: 2,
        nonce: encrypted['nonce'] as String,
        authTag: encrypted['authTag'] as String,
        keyEpoch: encrypted['keyEpoch'] as int,
        isEdited: true,
        editedAt: now,
        version: original.version + 1,
      );
      _upsertMessage(updated);
      await _cacheMessage(updated);
      state = state.copyWith(clearEditDraft: true);

      await _api.editMessageV2(
        conversationId,
        messageId,
        ciphertext: encrypted['ciphertext'] as String,
        nonce: encrypted['nonce'] as String,
        authTag: encrypted['authTag'] as String,
        keyEpoch: encrypted['keyEpoch'] as int,
        version: original.version,
      );
    } catch (error) {
      _upsertMessage(original);
      await _cacheMessage(original);
      if (mounted) state = state.copyWith(error: 'Edit failed: $error');
    }
  }


  Future<void> unsendMessage(String messageId) async {
    final msg = state.messages.firstWhere(
      (m) => m.id == messageId,
      orElse: () => throw StateError('Message not found'),
    );

    if (msg.senderId != _myUserId) return;

    // Capture the media reference before the optimistic wipe clears it, so
    // the server can purge the file from storage along with the unsend.
    final mediaId = msg.mediaRef?.id;

    try {
      await _api.unsendMessage(conversationId, messageId);
      state = state.copyWith(
        messages:
            state.messages.where((message) => message.id != messageId).toList(),
        clearReplyTo: state.replyTo?.id == messageId,
      );
      await LocalDb.instance.deleteMessage(messageId);
      if (mediaId != null) {
        await _ref.read(mediaServiceProvider).purgeLocal(mediaId);
      }
    } catch (e) {
      if (mounted) state = state.copyWith(error: 'Unsend failed: $e');
    }
  }

  Future<void> deleteForMe(String messageId) async {
    await _deleteMessagesForMe([messageId]);
  }

  Future<void> deleteSelectedForMe() async {
    final ids = {...state.selectedMessageIds};
    exitSelectionMode();
    await _deleteMessagesForMe(ids.toList());
  }

  Future<void> reactToMessage(String messageId, String emoji) async {
    final existing = state.messages.where((m) => m.id == messageId).firstOrNull;
    if (existing == null) return;

    // Toggle off if same reaction, otherwise set new reaction
    final newReaction = existing.reaction == emoji ? null : emoji;

    // Optimistic update
    final updated = state.messages.map((m) {
      if (m.id == messageId) {
        return m.copyWith(
          reaction: newReaction,
          clearReaction: newReaction == null,
        );
      }
      return m;
    }).toList();
    state = state.copyWith(messages: updated);
    await LocalDb.instance.updateMessageReaction(messageId, newReaction);

    try {
      await _api.sendReaction(conversationId, messageId, emoji);
    } catch (_) {
      // Revert if API fails
      final reverted = state.messages.map((m) {
        if (m.id == messageId) {
          return m.copyWith(
            reaction: existing.reaction,
            clearReaction: existing.reaction == null,
          );
        }
        return m;
      }).toList();
      state = state.copyWith(messages: reverted);
      await LocalDb.instance
          .updateMessageReaction(messageId, existing.reaction);
    }
  }

  Future<void> _deleteMessagesForMe(List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    final originals = state.messages
        .where((message) => messageIds.contains(message.id))
        .toList();
    final ids = originals.map((message) => message.id).toSet();
    if (ids.isEmpty) return;

    state = state.copyWith(
      messages: state.messages
          .map((message) => ids.contains(message.id)
              ? message.copyWith(
                  isLocallyDeleted: true, clearDecryptedText: true)
              : message)
          .toList(),
    );
    for (final id in ids) {
      await LocalDb.instance.markLocallyDeleted(id);
    }
  }


  // Typing indicator (outgoing)

  Timer? _outgoingTypingTimer;
  bool _outgoingTyping = false;

  void onUserTyping() {
    if (!_outgoingTyping) {
      _outgoingTyping = true;
      _ws?.sendTypingStart();
    }
    _outgoingTypingTimer?.cancel();
    _outgoingTypingTimer = Timer(const Duration(seconds: 3), () {
      _outgoingTyping = false;
      _ws?.sendTypingStop();
    });
  }

  void onUserStoppedTyping() {
    _outgoingTypingTimer?.cancel();
    if (_outgoingTyping) {
      _outgoingTyping = false;
      _ws?.sendTypingStop();
    }
  }

  void setReplyTo(Message message) {
    state = state.copyWith(replyTo: message, clearEditDraft: true);
  }

  void clearReplyTo() {
    state = state.copyWith(clearReplyTo: true);
  }

  void startEdit(Message message) {
    if (message.senderId != _myUserId || !message.isEditEligible) return;
    state = state.copyWith(
      editDraft: EditDraft(
        message: message,
        text: message.decryptedText ?? '',
      ),
      clearReplyTo: true,
    );
  }

  void clearEditDraft() {
    state = state.copyWith(clearEditDraft: true);
  }

  // Multi-select mode

  void enterSelectionMode(String firstMessageId) {
    state = state.copyWith(
      isSelectionMode: true,
      selectedMessageIds: {firstMessageId},
    );
  }

  void toggleSelection(String messageId) {
    final current = {...state.selectedMessageIds};
    if (current.contains(messageId)) {
      current.remove(messageId);
    } else {
      current.add(messageId);
    }
    state = state.copyWith(selectedMessageIds: current);
  }

  void exitSelectionMode() {
    state = state.copyWith(
      isSelectionMode: false,
      selectedMessageIds: {},
    );
  }

  int _compareMessages(Message a, Message b) => compareMessages(a, b);

  void _upsertMessage(Message msg) {
    final list = [...state.messages];
    final idx = list.indexWhere((m) => m.id == msg.id);
    if (idx != -1) {
      list[idx] = msg;
    } else {
      // Insert in chronological order
      final insertAt = list.indexWhere(
        (message) => _compareMessages(message, msg) > 0,
      );
      if (insertAt == -1) {
        list.add(msg);
      } else {
        list.insert(insertAt, msg);
      }
    }
    state = state.copyWith(messages: list);
  }

  void _updateMessageStatus(String messageId, MessageStatus status) {
    final updated = state.messages.map((m) {
      if (m.id == messageId) return m.copyWith(status: status);
      return m;
    }).toList();
    state = state.copyWith(messages: updated);
  }

  // Dispose

  @override
  void dispose() {
    _ws?.onConnectionChanged = null;
    _outgoingTypingTimer?.cancel();
    _typingTimer?.cancel();
    _expiryTimer?.cancel();
    _wsSub?.cancel();
    _ws?.dispose();
    super.dispose();
  }
}

final conversationProvider = StateNotifierProvider.autoDispose
    .family<ConversationNotifier, ConversationState, String>(
  (ref, conversationId) {
    final api = ref.watch(apiServiceProvider);
    final auth = ref.watch(authProvider);
    final myUserId = auth.user?.id ?? '';

    return ConversationNotifier(
      conversationId: conversationId,
      api: api,
      myUserId: myUserId,
      ref: ref,
    );
  },
);
