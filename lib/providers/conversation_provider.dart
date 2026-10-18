import 'dart:async';

import 'package:flexiyo/models/conversation.dart';
import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/providers/chat_provider.dart';
import 'package:flexiyo/providers/signal_crypto_provider.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/services/media_service.dart';
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
  final bool isSending;
  final String? error;

  /// True when the remote peer is typing.
  final bool isTyping;

  /// Message the user wants to reply to.
  final Message? replyTo;

  /// Non-null when the user is editing a sent message.
  final EditDraft? editDraft;

  /// IDs of messages selected in multi-select mode.
  final Set<String> selectedMessageIds;

  final bool isSelectionMode;

  ConversationState copyWith({
    Conversation? conversation,
    List<Message>? messages,
    bool? isLoading,
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

    // Drop stale local rows before they are rendered; the server has either
    // deleted them or marked them expired.
    try {
      await LocalDb.instance.purgeExpiredMessages(conversationId);
    } catch (_) {}

    final cachedConversation = _ref
        .read(chatsProvider)
        .conversations
        .where((conversation) => conversation.id == conversationId)
        .firstOrNull;
    if (cachedConversation != null) {
      state = state.copyWith(conversation: cachedConversation);
    }

    // Load from local cache first for instant display
    try {
      final cachedRows = await LocalDb.instance.getMessages(conversationId);
      final cached = cachedRows.reversed.map(Message.fromDbJson).toList();
      if (cached.isNotEmpty) {
        state = state.copyWith(messages: cached);
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

      final latestCached = state.messages.isEmpty
          ? null
          : state.messages.reduce(
              (a, b) => a.createdAt.isAfter(b.createdAt) ? a : b,
            );
      final messages = await _api.getMessages(
        conversationId,
        limit: 60,
        after: latestCached == null
            ? null
            : latestCached.createdAt.millisecondsSinceEpoch ~/ 1000,
      )
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final crypto = await _ref.read(signalCryptoProvider(_myUserId).future);
      final cachedById = {
        for (final message in state.messages) message.id: message
      };
      final hydratedMessages = [...state.messages];

      for (final msg in messages) {
        Message hydrated;
        if (msg.isUnsent || msg.encryptedPayload == null) {
          hydrated = msg;
        } else {
          final localText = cachedById[msg.id]?.decryptedText ??
              await crypto.getLocalMessageText(msg.id);
          if (localText != null) {
            hydrated = msg.copyWith(decryptedText: localText);
          } else if (msg.senderId == _myUserId) {
            final ownText = await crypto.getLocalMessageText(msg.id);
            hydrated = msg.copyWith(decryptedText: ownText);
          } else {
            try {
              final plaintext = await crypto.decryptFromUser(
                senderId: msg.senderId,
                payload: msg.encryptedPayload!,
                messageType: msg.messageType.name,
              );
              await crypto.saveLocalMessageText(msg.id, plaintext);
              hydrated = msg.copyWith(decryptedText: plaintext);
            } catch (_) {
              hydrated = msg;
            }
          }
        }

        final existingIndex =
            hydratedMessages.indexWhere((message) => message.id == msg.id);
        if (existingIndex == -1) {
          hydratedMessages.add(hydrated);
        } else {
          hydratedMessages[existingIndex] = hydrated;
        }
        await LocalDb.instance.upsertMessage(hydrated.toJson());
      }

      hydratedMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      if (mounted) {
        state = state.copyWith(
          conversation: conv,
          messages: hydratedMessages,
          isLoading: false,
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

  Future<bool> _isRestricted() async {
    final states = await LocalDb.instance.getChatStates();
    final row = states[conversationId];
    return row != null && (row['is_restricted'] as int? ?? 0) == 1;
  }

  Future<void> _connectWs() async {
    try {
      final wsUrl = await _api.buildWsUrl(conversationId);
      _ws = WsService(conversationId: conversationId, wsUrl: wsUrl);
      await _ws!.connect();

      _wsSub = _ws!.events.listen((event) => _handleWsEvent(event));
    } catch (_) {
      // WS connection failure is non-fatal; the next screen open retries it.
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
    if (msgId == null) return;

    final senderId = event['senderId'] as String? ?? '';
    final encryptedPayload = event['encryptedPayload'] as String? ?? '';
    final messageType = event['messageType'] as String? ?? 'signal';
    final replyToId = event['replyToId'] as String?;
    final createdAtRaw = event['createdAt'];
    final expiresAtRaw = event['expiresAt'];

    DateTime createdAt;
    if (createdAtRaw is int) {
      final ts = createdAtRaw > 1e12 ? createdAtRaw : createdAtRaw * 1000;
      createdAt = DateTime.fromMillisecondsSinceEpoch(ts.toInt());
    } else {
      createdAt = DateTime.now();
    }

    DateTime? expiresAt;
    if (expiresAtRaw is int) {
      final ts = expiresAtRaw > 1e12 ? expiresAtRaw : expiresAtRaw * 1000;
      expiresAt = DateTime.fromMillisecondsSinceEpoch(ts.toInt());
    }

    // Deduplicate
    if (state.messages.any((m) => m.id == msgId)) return;

    String? plaintext;
    if (senderId == _myUserId) {
      try {
        final crypto = await _ref.read(signalCryptoProvider(_myUserId).future);
        final local = await crypto.getLocalMessageText(msgId);
        if (local != null) plaintext = local;
      } catch (_) {}
    } else if (encryptedPayload.isNotEmpty) {
      try {
        final crypto = await _ref.read(signalCryptoProvider(_myUserId).future);
        plaintext = await crypto.decryptFromUser(
          senderId: senderId,
          payload: encryptedPayload,
          messageType: messageType,
        );
        await crypto.saveLocalMessageText(msgId, plaintext);
      } catch (_) {
        // Never surface ciphertext as message text. Leave plaintext null so the
        // bubble renders a neutral decryption-failed state.
        plaintext = null;
      }
    }

    final msg = Message(
      id: msgId,
      conversationId: conversationId,
      senderId: senderId,
      encryptedPayload: encryptedPayload,
      decryptedText: plaintext,
      messageType: MessageType.values.firstWhere(
        (e) => e.name == messageType,
        orElse: () => MessageType.signal,
      ),
      version: 1,
      createdAt: createdAt,
      expiresAt: expiresAt,
      status: MessageStatus.sent,
      replyToId: replyToId,
    );

    _upsertMessage(msg);
    await LocalDb.instance.upsertMessage(msg.toJson());
    _scheduleExpiryPurge();

    // Only acknowledge delivery once the payload is durably stored and, for
    // incoming messages, successfully decrypted.
    final decryptionOk = senderId == _myUserId || plaintext != null;
    if (decryptionOk) {
      _ws?.sendDeliveryAck(msgId);
    }

    final isIncoming = senderId != _myUserId;
    if (isIncoming &&
        state.conversation?.requestStatus == 'accepted' &&
        !(await _isRestricted())) {
      unawaited(_markConversationRead());
    }

    // Media envelopes render as a friendly label in the chat list.
    final mediaPreview = plaintext != null ? MediaRef.parse(plaintext) : null;
    _ref.read(chatsProvider.notifier).onNewMessage(
          conversationId: conversationId,
          preview: mediaPreview?.label ?? (plaintext ?? 'Message'),
          lastMessageAt: createdAt,
          isIncoming: isIncoming,
        );
  }

  /// The disappearing timer is shared: whichever side changes it, both open
  /// chats follow immediately.
  void _onDisappearingTimerChanged(Map<String, dynamic> event) {
    final timer = event['timer'];
    final current = state.conversation;
    if (timer is! int || current == null) return;
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
        unawaited(LocalDb.instance.upsertMessage(message.toJson()));
      }
    }
    _purgeExpiredMessages();

    _ref.read(chatsProvider.notifier).markPeerSeen(conversationId, readAt);
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
          unawaited(LocalDb.instance.upsertMessage(message.toJson()));
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
        unawaited(_deleteSecureMessageText(message.id));
        unawaited(LocalDb.instance.deleteMessage(message.id));
      }
    }
    _scheduleExpiryPurge();
  }

  Future<void> _onRemoteMessageEdited(Map<String, dynamic> event) async {
    final msgId = event['messageId'] as String?;
    if (msgId == null) return;

    final encryptedPayload = event['encryptedPayload'] as String? ?? '';
    final messageType = event['messageType'] as String? ?? 'signal';
    final version = (event['version'] as int?) ?? 1;
    final editedAtRaw = event['editedAt'];
    DateTime? editedAt;
    if (editedAtRaw is int) {
      final ts = editedAtRaw > 1e12 ? editedAtRaw : editedAtRaw * 1000;
      editedAt = DateTime.fromMillisecondsSinceEpoch(ts.toInt());
    }

    final original = state.messages.where((m) => m.id == msgId).firstOrNull;
    if (original == null) return;

    final crypto = await _ref.read(signalCryptoProvider(_myUserId).future);
    String? plaintext;
    if (original.senderId == _myUserId) {
      plaintext =
          await crypto.getLocalMessageText(msgId) ?? original.decryptedText;
    } else {
      try {
        plaintext = await crypto.decryptFromUser(
          senderId: original.senderId,
          payload: encryptedPayload,
          messageType: messageType,
        );
      } catch (_) {
        plaintext = null;
      }
    }
    if (plaintext != null && original.senderId != _myUserId) {
      try {
        await crypto.saveLocalMessageText(msgId, plaintext);
      } catch (_) {}
    }

    final updated = state.messages.map((m) {
      if (m.id == msgId) {
        return m.copyWith(
          encryptedPayload: encryptedPayload,
          messageType:
              messageType == 'prekey' ? MessageType.prekey : MessageType.signal,
          decryptedText: plaintext,
          version: version,
          isEdited: true,
          editedAt: editedAt,
          status: MessageStatus.sent,
        );
      }
      return m;
    }).toList();

    state = state.copyWith(messages: updated);
    if (plaintext != null) {
      await crypto.saveLocalMessageText(msgId, plaintext);
    }

    if (editedAt != null) {
      LocalDb.instance.updateMessageEdited(
        msgId,
        encryptedPayload: encryptedPayload,
        version: version,
        editedAt: editedAt.millisecondsSinceEpoch,
      );
    }
  }

  void _onRemoteMessageDeleted(Map<String, dynamic> event) {
    final msgId = event['messageId'] as String?;
    if (msgId == null) return;

    state = state.copyWith(
      messages: state.messages.where((message) => message.id != msgId).toList(),
      clearReplyTo: state.replyTo?.id == msgId,
    );
    unawaited(_deleteSecureMessageText(msgId));
    unawaited(LocalDb.instance.deleteMessage(msgId));
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

  Future<void> sendMessage(String text) async {
    var conv = state.conversation;
    if (conv == null) {
      try {
        conv = await _api.getConversation(conversationId);
        if (mounted) state = state.copyWith(conversation: conv);
      } catch (_) {}
    }
    if (text.isEmpty || conv == null || state.isSending) return;
    if (await _isRestricted()) {
      if (mounted) {
        state = state.copyWith(error: 'Unrestrict this chat to send messages');
      }
      return;
    }
    if (conv.requestStatus == 'pending' && conv.initiatedById != _myUserId) {
      return;
    }
    if (conv.requestStatus == 'pending' &&
        state.messages
            .any((m) => !m.isUnsent && m.status != MessageStatus.failed)) {
      return;
    }

    final msgId = _uuid.v4();
    final now = DateTime.now();
    final replyToId = state.replyTo?.id;

    // Optimistic message
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
    );

    _upsertMessage(optimistic);
    await LocalDb.instance.upsertMessage(optimistic.toJson());
    state = state.copyWith(clearReplyTo: true);

    // Update chats list preview.
    final optimisticPreview = MediaRef.parse(text);
    _ref.read(chatsProvider.notifier).onNewMessage(
          conversationId: conversationId,
          preview: optimisticPreview?.label ?? text,
          lastMessageAt: now,
        );

    state = state.copyWith(isSending: true);

    try {
      final crypto = await _ref.read(signalCryptoProvider(_myUserId).future);
      final encrypted = await crypto.encryptForUser(conv.otherUserId, text);
      await crypto.saveLocalMessageText(msgId, text);
      await _api.sendMessage(
        conversationId,
        recipientId: conv.otherUserId,
        encryptedPayload: encrypted.payload,
        messageType: encrypted.messageType,
        messageId: msgId,
        replyToId: replyToId,
      );

      // Confirm as sent
      _updateMessageStatus(msgId, MessageStatus.sent);
      final sent = optimistic.copyWith(
        encryptedPayload: encrypted.payload,
        messageType: encrypted.messageType == 'prekey'
            ? MessageType.prekey
            : MessageType.signal,
        status: MessageStatus.sent,
      );
      _upsertMessage(sent);
      try {
        final row = sent.toJson();
        await LocalDb.instance.upsertMessage(row);
      } catch (_) {}
    } catch (e) {
      _updateMessageStatus(msgId, MessageStatus.failed);
      final errorStr = e.toString();
      final userFriendlyError = errorStr.contains('No device registered')
          ? "Recipient hasn't registered encryption keys yet."
          : 'Send failed: $e';
      if (mounted) state = state.copyWith(error: userFriendlyError);
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
    await sendMessage(text);
  }

  Future<void> editMessage(String messageId, String newText) async {
    final original = state.messages.firstWhere(
      (m) => m.id == messageId,
      orElse: () => throw StateError('Message not found'),
    );

    if (original.senderId != _myUserId) return;
    if (!original.isEditEligible) return;

    // Optimistic update
    final now = DateTime.now();
    final conversation = state.conversation;
    if (conversation == null) return;

    final crypto = await _ref.read(signalCryptoProvider(_myUserId).future);
    final encrypted =
        await crypto.encryptForUser(conversation.otherUserId, newText);
    await crypto.saveLocalMessageText(messageId, newText);
    _upsertMessage(
      original.copyWith(
        decryptedText: newText,
        encryptedPayload: encrypted.payload,
        isEdited: true,
        editedAt: now,
        version: original.version + 1,
      ),
    );

    state = state.copyWith(clearEditDraft: true);

    try {
      await _api.editMessage(
        conversationId,
        messageId,
        encryptedPayload: encrypted.payload,
        version: original.version,
        messageType: encrypted.messageType,
      );
    } catch (e) {
      // Rollback
      _upsertMessage(original);
      if (original.decryptedText != null) {
        try {
          final crypto =
              await _ref.read(signalCryptoProvider(_myUserId).future);
          await crypto.saveLocalMessageText(messageId, original.decryptedText!);
        } catch (_) {}
      }
      if (mounted) state = state.copyWith(error: 'Edit failed: $e');
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
      await _api.unsendMessage(conversationId, messageId, mediaId: mediaId);
      state = state.copyWith(
        messages:
            state.messages.where((message) => message.id != messageId).toList(),
        clearReplyTo: state.replyTo?.id == messageId,
      );
      await _deleteSecureMessageText(messageId);
      await LocalDb.instance.deleteMessage(messageId);
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

    try {
      final crypto = await _ref.read(signalCryptoProvider(_myUserId).future);
      for (final id in ids) {
        await crypto.deleteLocalMessageText(id);
      }
    } catch (_) {}
  }

  Future<void> _deleteSecureMessageText(String messageId) async {
    try {
      final crypto = await _ref.read(signalCryptoProvider(_myUserId).future);
      await crypto.deleteLocalMessageText(messageId);
    } catch (_) {}
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

  void _upsertMessage(Message msg) {
    final list = [...state.messages];
    final idx = list.indexWhere((m) => m.id == msg.id);
    if (idx != -1) {
      list[idx] = msg;
    } else {
      // Insert in chronological order
      final insertAt =
          list.indexWhere((m) => m.createdAt.isAfter(msg.createdAt));
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
