import 'dart:async';

import 'package:flexiyo/models/conversation.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/services/ws_service.dart';
import 'package:flexiyo/storage/local_db.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// State

class ChatsState {
  const ChatsState({
    this.conversations = const [],
    this.requestCount = 0,
    this.isLoading = false,
    this.error,
  });

  final List<Conversation> conversations;
  final int requestCount;
  final bool isLoading;
  final String? error;

  ChatsState copyWith({
    List<Conversation>? conversations,
    int? requestCount,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return ChatsState(
      conversations: conversations ?? this.conversations,
      requestCount: requestCount ?? this.requestCount,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

// Notifier

class ChatsNotifier extends StateNotifier<ChatsState> {
  ChatsNotifier(this._api) : super(const ChatsState());

  final ApiService _api;
  bool _initialized = false;
  WsService? _inboxWs;
  StreamSubscription<Map<String, dynamic>>? _inboxWsSub;

  static List<Conversation> _sort(List<Conversation> items) {
    final list = [...items];
    list.sort((a, b) {
      if (a.isPinned != b.isPinned) {
        return a.isPinned ? -1 : 1;
      }
      final aTime = a.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = b.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });
    return list;
  }

  /// Load conversations — first from cache, then one single-seed refresh.
  /// After seeding, all updates are pushed over the inbox WebSocket; there is
  /// no polling anywhere in the app.
  Future<void> load({bool forceRefresh = false}) async {
    if (state.isLoading) return;

    await _connectInboxWs();

    if (!_initialized || forceRefresh) {
      state = state.copyWith(isLoading: true, clearError: true);

      // Show cached conversations immediately while the seed request runs
      if (!_initialized) {
        try {
          final rows = await LocalDb.instance.getAllConversations();
          final cached = rows.map((r) => _conversationFromDbRow(r)).toList();
          if (cached.isNotEmpty) {
            state = state.copyWith(conversations: _sort(cached));
          }
        } catch (_) {
          // ignore cache errors — server will provide data
        }
        _initialized = true;
      }

      try {
        // One round trip: accepted chats + request queue together.
        final seed = await _api.getConversationSeed();

        final cachedById = {
          for (final conv in state.conversations) conv.id: conv
        };
        Conversation merge(Conversation conversation) {
          final cached = cachedById[conversation.id];
          final sameLatestMessage = cached?.lastMessageAt != null &&
              conversation.lastMessageAt != null &&
              cached!.lastMessageAt!.millisecondsSinceEpoch ~/ 1000 ==
                  conversation.lastMessageAt!.millisecondsSinceEpoch ~/ 1000;
          return sameLatestMessage
              ? conversation.copyWith(
                  lastMessagePreview: cached.lastMessagePreview,
                  unreadCount: cached.unreadCount,
                  isPinned: cached.isPinned,
                  isMuted: cached.isMuted,
                  isRestricted: cached.isRestricted,
                )
              : conversation;
        }

        final merged = seed.conversations.map(merge).toList();
        final sorted = _sort(merged);

        // Persist to local cache
        for (final conv in sorted) {
          await LocalDb.instance.upsertConversation(_conversationToDbRow(conv));
        }
        if (mounted) {
          state = state.copyWith(
            conversations: sorted,
            requestCount: seed.requests.length,
            isLoading: false,
          );
        }
      } catch (e) {
        if (mounted) {
          state = state.copyWith(
            isLoading: false,
            error: e.toString(),
          );
        }
      }
    }
  }

  Future<void> _connectInboxWs() async {
    if (_inboxWs != null) return;
    try {
      final url = await _api.buildInboxWsUrl();
      final ws = WsService(wsUrl: url);
      _inboxWs = ws;
      _inboxWsSub = ws.events.listen(_handleInboxEvent);
      await ws.connect();
    } catch (_) {
      await disconnect();
    }
  }

  bool _resyncing = false;

  /// Silent repair for state that arrived partially over the socket (e.g. a
  /// brand-new conversation tile). Consumes one seed call, rate-guarded.
  Future<void> _resync() async {
    if (_resyncing) return;
    _resyncing = true;
    try {
      final seed = await _api.getConversationSeed();
      if (!mounted) return;
      final merged = _sort(seed.conversations);
      state = state.copyWith(
        conversations: merged,
        requestCount: seed.requests.length,
        clearError: true,
      );
      for (final conv in merged) {
        await LocalDb.instance.upsertConversation(_conversationToDbRow(conv));
      }
    } catch (_) {
      // Socket-event repair is best-effort; pull-to-refresh is the fallback.
    } finally {
      _resyncing = false;
    }
  }

  void _handleInboxEvent(Map<String, dynamic> event) {
    switch (event['type'] as String?) {
      case 'inbox_message':
        if (event['isIncoming'] != true) return;
        final conversationId = event['conversationId'] as String?;
        if (conversationId == null) return;

        final exists = state.conversations.any((c) => c.id == conversationId);
        if (!exists) {
          // Brand-new chat pushed over the socket while this client had no
          // tile for it — repair the list once (never a poll loop).
          unawaited(_resync());
          return;
        }

        final seconds =
            event['lastMessageAt'] is int ? event['lastMessageAt'] as int : 0;
        onNewMessage(
          conversationId: conversationId,
          preview: event['preview'] as String? ?? 'New message',
          lastMessageAt: DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
          isIncoming: true,
        );
        break;
      case 'conversation_upsert':
        final payload = event['conversation'];
        if (payload is Map<String, dynamic>) {
          final conversation = Conversation.fromJson(payload);
          // Events are already user-scoped (built per recipient inbox), so a
          // pending tile addressed to me as the RECIPIENT feeds the requests
          // badge; pending tiles for my own outgoing chats stay in the list.
          if (conversation.requestStatus == 'pending' &&
              conversation.initiatedById != null &&
              conversation.initiatedById == conversation.otherUserId) {
            final remaining = state.conversations
                .where((c) => c.id != conversation.id)
                .toList();
            state = state.copyWith(
              conversations: remaining,
              requestCount: state.requestCount + 1,
              clearError: true,
            );
            LocalDb.instance
                .upsertConversation(_conversationToDbRow(conversation));
          } else {
            final wasInRequests = state.requestCount > 0 &&
                !state.conversations.any((c) => c.id == conversation.id);
            unawaited(upsertConversation(conversation));
            if (wasInRequests &&
                (conversation.requestStatus == 'accepted' ||
                    conversation.requestStatus == 'rejected')) {
              // A request from the queue transformed into (or vanished from)
              // the main list — drain one from the badge.
              state = state.copyWith(
                requestCount: (state.requestCount - 1).clamp(0, 1 << 30),
              );
            }
          }
        }
        break;
      case 'conversation_removed':
        final conversationId = event['conversationId'] as String?;
        if (conversationId != null) {
          unawaited(removeConversation(conversationId));
        }
        break;
      case 'unread_reset':
        final conversationId = event['conversationId'] as String?;
        if (conversationId != null) {
          markRead(conversationId);
        }
        break;
      case 'message_unsent':
        final conversationId = event['conversationId'] as String?;
        if (conversationId != null) {
          onMessageUnsent(conversationId);
        }
        break;
      default:
        break;
    }
  }


  Future<void> disconnect() async {
    await _inboxWsSub?.cancel();
    _inboxWsSub = null;
    await _inboxWs?.dispose();
    _inboxWs = null;
  }

  Future<void> reset() async {
    await disconnect();
    _initialized = false;
    state = const ChatsState();
  }

  @override
  void dispose() {
    unawaited(disconnect());
    super.dispose();
  }

  Future<void> upsertConversation(Conversation conversation) async {
    final conversations = [...state.conversations]
      ..removeWhere((item) => item.id == conversation.id);
    conversations.insert(0, conversation);
    state = state.copyWith(
      conversations: _sort(conversations),
      clearError: true,
    );
    await LocalDb.instance
        .upsertConversation(_conversationToDbRow(conversation));
  }

  /// Delete conversation locally only — zero server tracking for privacy.
  Future<void> removeConversation(String conversationId) async {
    state = state.copyWith(
      conversations: state.conversations
          .where((conversation) => conversation.id != conversationId)
          .toList(),
    );
    await LocalDb.instance.deleteConversation(conversationId);
  }

  Future<void> togglePin(String conversationId) async {
    final list = [...state.conversations];
    final idx = list.indexWhere((c) => c.id == conversationId);
    if (idx == -1) return;
    final updated = list[idx].copyWith(isPinned: !list[idx].isPinned);
    list[idx] = updated;
    state = state.copyWith(conversations: _sort(list));
    await LocalDb.instance
        .updateConversationSettings(conversationId, isPinned: updated.isPinned);
    try {
      await _api.updateConversationSettings(conversationId,
          isPinned: updated.isPinned);
    } catch (_) {}
  }

  Future<void> toggleMute(String conversationId) async {
    final list = [...state.conversations];
    final idx = list.indexWhere((c) => c.id == conversationId);
    if (idx == -1) return;
    final updated = list[idx].copyWith(isMuted: !list[idx].isMuted);
    list[idx] = updated;
    state = state.copyWith(conversations: list);
    await LocalDb.instance
        .updateConversationSettings(conversationId, isMuted: updated.isMuted);
    try {
      await _api.updateConversationSettings(conversationId,
          isMuted: updated.isMuted);
    } catch (_) {}
  }

  Future<void> toggleRestrict(String conversationId) async {
    final list = [...state.conversations];
    final idx = list.indexWhere((c) => c.id == conversationId);
    if (idx == -1) return;
    final newRestricted = !list[idx].isRestricted;
    final updated = list[idx].copyWith(isRestricted: newRestricted);
    if (newRestricted) {
      // Moves out of main inbox into requests section
      list.removeAt(idx);
    } else {
      list[idx] = updated;
    }
    state = state.copyWith(conversations: _sort(list));
    await LocalDb.instance.updateConversationSettings(conversationId,
        isRestricted: newRestricted);
    try {
      await _api.updateConversationSettings(conversationId,
          isRestricted: newRestricted);
    } catch (_) {}
  }

  // Real-time updates (called from ConversationNotifier / WsService events)

  /// Update the conversation preview when a new message arrives or is sent.
  void onNewMessage({
    required String conversationId,
    required String preview,
    required DateTime lastMessageAt,
    bool isIncoming = false,
  }) {
    final list = [...state.conversations];
    final idx = list.indexWhere((c) => c.id == conversationId);
    if (idx == -1) return;

    final current = list[idx];
    if (isIncoming &&
        current.lastMessageAt != null &&
        !current.lastMessageAt!.isBefore(lastMessageAt)) {
      return;
    }

    final updated = current.copyWith(
      lastMessagePreview: preview,
      lastMessageAt: lastMessageAt,
      unreadCount:
          isIncoming ? list[idx].unreadCount + 1 : list[idx].unreadCount,
    );

    list[idx] = updated;
    state = state.copyWith(conversations: _sort(list));

    // Persist preview to cache
    LocalDb.instance.updateConversationPreview(
      conversationId,
      preview: preview,
      lastMessageAt: lastMessageAt.millisecondsSinceEpoch,
      unreadDelta: isIncoming ? 1 : 0,
    );
  }

  /// Mark all messages in a conversation as read (clear unread count).
  void markRead(String conversationId) {
    final list = [...state.conversations];
    final idx = list.indexWhere((c) => c.id == conversationId);
    if (idx == -1) return;

    if (list[idx].unreadCount == 0) return;

    list[idx] = list[idx].copyWith(unreadCount: 0);
    state = state.copyWith(conversations: list);
    LocalDb.instance.clearUnreadCount(conversationId);
  }

  /// Update the preview when a message is unsent (retracted).
  void onMessageUnsent(String conversationId) {
    final list = [...state.conversations];
    final idx = list.indexWhere((c) => c.id == conversationId);
    if (idx == -1) return;

    list[idx] = list[idx].copyWith(lastMessagePreview: 'Message unsent');
    state = state.copyWith(conversations: list);
  }

  void updateRequestCount(int count) {
    state = state.copyWith(requestCount: count);
  }

  // Helpers

  static Conversation _conversationFromDbRow(Map<String, dynamic> row) {
    final lastMessageAtMs = row['last_message_at'] as int?;
    return Conversation(
      id: row['id'] as String,
      otherUserId: row['other_user_id'] as String,
      otherUsername: row['other_username'] as String,
      disappearingTimer: (row['disappearing_timer'] as int?) ?? 0,
      lastMessageAt: lastMessageAtMs != null
          ? DateTime.fromMillisecondsSinceEpoch(lastMessageAtMs)
          : null,
      lastMessagePreview: row['last_message_preview'] as String?,
      unreadCount: (row['unread_count'] as int?) ?? 0,
      isPinned: (row['is_pinned'] as int?) == 1,
      isMuted: (row['is_muted'] as int?) == 1,
      isRestricted: (row['is_restricted'] as int?) == 1,
    );
  }

  static Map<String, dynamic> _conversationToDbRow(Conversation conv) => {
        'id': conv.id,
        'other_user_id': conv.otherUserId,
        'other_username': conv.otherUsername,
        'disappearing_timer': conv.disappearingTimer,
        if (conv.lastMessageAt != null)
          'last_message_at': conv.lastMessageAt!.millisecondsSinceEpoch,
        if (conv.lastMessagePreview != null)
          'last_message_preview': conv.lastMessagePreview,
        'unread_count': conv.unreadCount,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'is_pinned': conv.isPinned ? 1 : 0,
        'is_muted': conv.isMuted ? 1 : 0,
        'is_restricted': conv.isRestricted ? 1 : 0,
      };
}

// Provider

final chatsProvider = StateNotifierProvider<ChatsNotifier, ChatsState>((ref) {
  final api = ref.watch(apiServiceProvider);
  final notifier = ChatsNotifier(api);
  ref.onDispose(notifier.dispose);
  return notifier;
});
