import 'dart:async';

import 'package:flexiyo/models/conversation.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/services/ws_service.dart';
import 'package:flexiyo/storage/local_db.dart';
import 'package:flutter_riverpod/legacy.dart';

class ChatsState {
  const ChatsState({
    this.conversations = const [],
    this.restrictedChats = const [],
    this.blockedChats = const [],
    this.requestCount = 0,
    this.isLoading = false,
    this.error,
    this.hasLoaded = false,
  });

  final List<Conversation> conversations;
  final List<Conversation> restrictedChats;
  final List<Conversation> blockedChats;
  final int requestCount;
  final bool isLoading;
  final String? error;

  /// True once the first server seed (or a failed attempt) has been applied,
  /// so empty states are not flashed while the initial load is in flight.
  final bool hasLoaded;

  ChatsState copyWith({
    List<Conversation>? conversations,
    List<Conversation>? restrictedChats,
    List<Conversation>? blockedChats,
    int? requestCount,
    bool? isLoading,
    String? error,
    bool clearError = false,
    bool? hasLoaded,
  }) {
    return ChatsState(
      conversations: conversations ?? this.conversations,
      restrictedChats: restrictedChats ?? this.restrictedChats,
      blockedChats: blockedChats ?? this.blockedChats,
      requestCount: requestCount ?? this.requestCount,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      hasLoaded: hasLoaded ?? this.hasLoaded,
    );
  }
}

class ChatsNotifier extends StateNotifier<ChatsState> {
  ChatsNotifier(this._api) : super(const ChatsState());

  final ApiService _api;
  bool _initialized = false;
  WsService? _inboxWs;
  StreamSubscription<Map<String, dynamic>>? _inboxWsSub;

  /// Conversation currently on screen; incoming messages for it must not bump
  /// the unread badge the user is already looking at.
  String? _activeConversationId;

  static DateTime? _laterOf(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

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

  Future<List<Conversation>> _hydrate(List<Conversation> source) async {
    final states = await LocalDb.instance.getChatStates();
    final result = <Conversation>[];
    for (final conv in source) {
      final row = states[conv.id];
      if (row != null && (row['is_deleted'] as int? ?? 0) == 1) continue;
      result.add(conv.copyWith(
        isPinned: row != null && (row['is_pinned'] as int? ?? 0) == 1,
        isMuted: row != null && (row['is_muted'] as int? ?? 0) == 1,
        isRestricted: row != null && (row['is_restricted'] as int? ?? 0) == 1,
      ));
    }
    return result;
  }

  Future<void> _applySeed(List<Conversation> inbox, List<Conversation> requests,
      List<Conversation> blockedServer) async {
    final cached = [
      ...state.conversations,
      ...state.restrictedChats,
      ...state.blockedChats,
    ];
    final cachedById = {for (final conv in cached) conv.id: conv};

    Conversation merge(Conversation conversation) {
      final c = cachedById[conversation.id];
      if (c == null) return conversation;
      final sameLatestMessage = c.lastMessageAt != null &&
          conversation.lastMessageAt != null &&
          c.lastMessageAt!.millisecondsSinceEpoch ~/ 1000 ==
              conversation.lastMessageAt!.millisecondsSinceEpoch ~/ 1000;
      final peerSeenAt = _laterOf(c.peerSeenAt, conversation.peerSeenAt);
      return sameLatestMessage
          ? conversation.copyWith(
              lastMessagePreview: c.lastMessagePreview,
              unreadCount: c.unreadCount,
              isPinned: c.isPinned,
              isMuted: c.isMuted,
              isRestricted: c.isRestricted,
              peerSeenAt: peerSeenAt,
              lastMessageIsMine:
                  c.lastMessageIsMine || conversation.lastMessageIsMine,
            )
          : conversation.copyWith(peerSeenAt: peerSeenAt);
    }

    final hydrated = await _hydrate(
      [...inbox, ...requests, ...blockedServer].map(merge).toList(),
    );

    final byId = <String, Conversation>{};
    for (final conv in hydrated) {
      byId[conv.id] = conv;
    }
    final deduped = byId.values.toList();

    final active = <Conversation>[];
    final restricted = <Conversation>[];
    final blocked = <Conversation>[];
    final blockedIds = {for (final conv in blockedServer) conv.id};
    for (final conv in deduped) {
      if (conv.isRestricted) {
        restricted.add(conv);
      } else if (blockedIds.contains(conv.id)) {
        blocked.add(conv);
      } else {
        active.add(conv);
      }
    }

    final pendingCount = deduped
        .where((c) =>
            !c.isRestricted &&
            !blockedIds.contains(c.id) &&
            c.requestStatus == 'pending' &&
            c.initiatedById != null &&
            c.initiatedById == c.otherUserId)
        .length;

    final sortedActive = _sort(active);
    final sortedRestricted = _sort(restricted);
    final sortedBlocked = _sort(blocked);

    state = state.copyWith(
      conversations: sortedActive,
      restrictedChats: sortedRestricted,
      blockedChats: sortedBlocked,
      requestCount: pendingCount,
      isLoading: false,
      hasLoaded: true,
      clearError: true,
    );

    // Persist rows + local flags.
    for (final conv in deduped) {
      await LocalDb.instance.upsertConversation(_conversationToDbRow(conv));
      await LocalDb.instance.applyChatState(
        conv.id,
        isPinned: conv.isPinned,
        isMuted: conv.isMuted,
        isRestricted: conv.isRestricted,
      );
    }
  }

  Future<void> load({bool forceRefresh = false}) async {
    if (state.isLoading) return;

    await _connectInboxWs();

    if (!_initialized || forceRefresh) {
      state = state.copyWith(isLoading: true, clearError: true);

      if (!_initialized) {
        try {
          final rows = await LocalDb.instance.getAllConversations();
          final cached = rows.map(Conversation.fromDbJson).toList();
          if (cached.isNotEmpty) {
            state = state.copyWith(conversations: _sort(cached));
          }
          final restrictedRows =
              await LocalDb.instance.getRestrictedConversations();
          final blockedRows = await LocalDb.instance.getBlockedConversations();
          state = state.copyWith(
            restrictedChats:
                _sort(restrictedRows.map(Conversation.fromDbJson).toList()),
            blockedChats:
                _sort(blockedRows.map(Conversation.fromDbJson).toList()),
          );
        } catch (_) {}
        _initialized = true;
      }

      try {
        final seed = await _api.getConversationSeed();
        final blockedServer = await _api.getConversations(scope: 'blocked');
        await _applySeed(seed.conversations, seed.requests, blockedServer);
      } catch (e) {
        if (mounted) {
          state = state.copyWith(
            isLoading: false,
            error: e.toString(),
            hasLoaded: true,
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

  Future<void> _resync() async {
    if (_resyncing) return;
    _resyncing = true;
    try {
      final seed = await _api.getConversationSeed();
      final blockedServer = await _api.getConversations(scope: 'blocked');
      await _applySeed(seed.conversations, seed.requests, blockedServer);
    } catch (_) {
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

        final exists = state.conversations.any((c) => c.id == conversationId) ||
            state.restrictedChats.any((c) => c.id == conversationId) ||
            state.blockedChats.any((c) => c.id == conversationId);
        if (!exists) {
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
          unawaited(_hydrateUpsert(conversation));
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
      case 'conversation_refresh':
        unawaited(load(forceRefresh: true));
        break;
      default:
        break;
    }
  }

  Future<void> _hydrateUpsert(Conversation conversation) async {
    final states = await LocalDb.instance.getChatStates();
    final row = states[conversation.id];
    if (row != null && (row['is_deleted'] as int? ?? 0) == 1) return;

    final hydrated = conversation.copyWith(
      isPinned: row != null && (row['is_pinned'] as int? ?? 0) == 1,
      isMuted: row != null && (row['is_muted'] as int? ?? 0) == 1,
      isRestricted: row != null && (row['is_restricted'] as int? ?? 0) == 1,
    );

    // Upsert payloads do not carry preview/read-receipt state; keep the local
    // values while the latest message is unchanged.
    final local = _findConversation(conversation.id);
    final sameLatestMessage = local != null &&
        local.lastMessageAt != null &&
        hydrated.lastMessageAt != null &&
        local.lastMessageAt!.millisecondsSinceEpoch ~/ 1000 ==
            hydrated.lastMessageAt!.millisecondsSinceEpoch ~/ 1000;
    final merged = sameLatestMessage
        ? hydrated.copyWith(
            lastMessagePreview:
                hydrated.lastMessagePreview ?? local.lastMessagePreview,
            peerSeenAt: _laterOf(local.peerSeenAt, hydrated.peerSeenAt),
            lastMessageIsMine:
                local.lastMessageIsMine || hydrated.lastMessageIsMine,
          )
        : hydrated;

    final isBlocked = state.blockedChats.any((c) => c.id == conversation.id);

    if (hydrated.requestStatus == 'pending' &&
        hydrated.initiatedById != null &&
        hydrated.initiatedById == hydrated.otherUserId &&
        !hydrated.isRestricted) {
      final remaining =
          state.conversations.where((c) => c.id != conversation.id).toList();
      state = state.copyWith(
        conversations: remaining,
        requestCount: state.requestCount + 1,
        clearError: true,
      );
      await LocalDb.instance
          .upsertConversation(_conversationToDbRow(conversation));
      await LocalDb.instance.applyChatState(
        conversation.id,
        isPinned: hydrated.isPinned,
        isMuted: hydrated.isMuted,
        isRestricted: hydrated.isRestricted,
      );
      return;
    }

    final wasInRequests = state.requestCount > 0 &&
        !state.conversations.any((c) => c.id == conversation.id) &&
        !state.restrictedChats.any((c) => c.id == conversation.id) &&
        !state.blockedChats.any((c) => c.id == conversation.id);

    if (hydrated.isRestricted) {
      final list = [...state.restrictedChats]
        ..removeWhere((c) => c.id == conversation.id);
      list.insert(0, merged);
      state = state.copyWith(restrictedChats: _sort(list));
    } else if (isBlocked) {
      final list = [...state.blockedChats]
        ..removeWhere((c) => c.id == conversation.id);
      list.insert(0, merged);
      state = state.copyWith(blockedChats: _sort(list));
    } else {
      final list = [...state.conversations]
        ..removeWhere((c) => c.id == conversation.id);
      list.insert(0, merged);
      state = state.copyWith(conversations: _sort(list));
    }
    await LocalDb.instance
        .upsertConversation(_conversationToDbRow(conversation));
    await LocalDb.instance.applyChatState(
      conversation.id,
      isPinned: hydrated.isPinned,
      isMuted: hydrated.isMuted,
      isRestricted: hydrated.isRestricted,
    );
    if (wasInRequests &&
        (conversation.requestStatus == 'accepted' ||
            conversation.requestStatus == 'rejected')) {
      state = state.copyWith(
        requestCount: (state.requestCount - 1).clamp(0, 1 << 30),
      );
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
    state =
        state.copyWith(conversations: _sort(conversations), clearError: true);
    await LocalDb.instance
        .upsertConversation(_conversationToDbRow(conversation));
  }

  /// resurrecting it.
  Future<void> removeConversation(String conversationId) async {
    final messageIds =
        await LocalDb.instance.deleteConversationData(conversationId);
    await LocalDb.instance.applyChatState(conversationId, isDeleted: true);
    state = state.copyWith(
      conversations:
          state.conversations.where((c) => c.id != conversationId).toList(),
      restrictedChats:
          state.restrictedChats.where((c) => c.id != conversationId).toList(),
      blockedChats:
          state.blockedChats.where((c) => c.id != conversationId).toList(),
    );
    void _ = messageIds;
  }

  Future<void> togglePin(String conversationId) async {
    final list = [...state.conversations];
    final idx = list.indexWhere((c) => c.id == conversationId);
    if (idx == -1) return;
    final updated = list[idx].copyWith(isPinned: !list[idx].isPinned);
    list[idx] = updated;
    state = state.copyWith(conversations: _sort(list));
    await LocalDb.instance.applyChatState(
      conversationId,
      isPinned: updated.isPinned,
    );
  }

  Future<void> toggleMute(String conversationId) async {
    final list = [...state.conversations];
    final idx = list.indexWhere((c) => c.id == conversationId);
    if (idx == -1) return;
    final updated = list[idx].copyWith(isMuted: !list[idx].isMuted);
    list[idx] = updated;
    state = state.copyWith(conversations: list);
    await LocalDb.instance.applyChatState(
      conversationId,
      isMuted: updated.isMuted,
    );
  }

  Future<void> updateDisappearingTimer(
    String conversationId,
    int timerSeconds,
  ) async {
    final conversation = _findConversation(conversationId);
    if (conversation == null) return;

    await _api.updateDisappearingTimer(conversationId, timerSeconds);
    final updated = conversation.copyWith(disappearingTimer: timerSeconds);
    List<Conversation> update(List<Conversation> list) => [
          for (final item in list)
            if (item.id == conversationId) updated else item,
        ];

    state = state.copyWith(
      conversations: update(state.conversations),
      restrictedChats: update(state.restrictedChats),
      blockedChats: update(state.blockedChats),
    );
    await LocalDb.instance.upsertConversation(_conversationToDbRow(updated));
  }

  Future<void> toggleRestrict(String conversationId) async {
    final idx = state.conversations.indexWhere((c) => c.id == conversationId);
    if (idx == -1) return;
    final conv = state.conversations[idx];
    final newRestricted = !conv.isRestricted;
    final updated = conv.copyWith(isRestricted: newRestricted);
    final conversations = [...state.conversations]..removeAt(idx);
    final restricted = [...state.restrictedChats];
    if (newRestricted) {
      restricted.insert(0, updated);
    } else {
      conversations.add(updated);
    }
    state = state.copyWith(
      conversations: _sort(conversations),
      restrictedChats: _sort(restricted),
    );
    await LocalDb.instance.applyChatState(
      conversationId,
      isRestricted: newRestricted,
    );
  }

  Future<void> toggleBlock(String conversationId) async {
    final idx = state.conversations.indexWhere((c) => c.id == conversationId);
    if (idx == -1) return;
    final conv = state.conversations[idx];
    final conversations = [...state.conversations]..removeAt(idx);
    final blocked = [...state.blockedChats, conv];
    state = state.copyWith(
      conversations: _sort(conversations),
      blockedChats: _sort(blocked),
    );
    try {
      await _api.blockConversation(conversationId);
    } catch (_) {}
  }

  Future<void> unblock(String conversationId) async {
    final idx = state.blockedChats.indexWhere((c) => c.id == conversationId);
    if (idx == -1) return;
    final conv = state.blockedChats[idx];
    final blocked = [...state.blockedChats]..removeAt(idx);
    final conversations = [...state.conversations, conv];
    state = state.copyWith(
      conversations: _sort(conversations),
      blockedChats: _sort(blocked),
    );
    try {
      await _api.unblockConversation(conversationId);
    } catch (_) {}
  }

  Future<void> unrestrict(String conversationId) async {
    final idx = state.restrictedChats.indexWhere((c) => c.id == conversationId);
    if (idx == -1) return;
    final conv = state.restrictedChats[idx];
    final restricted = [...state.restrictedChats]..removeAt(idx);
    final updated = conv.copyWith(isRestricted: false);
    final conversations = [...state.conversations, updated];
    state = state.copyWith(
      conversations: _sort(conversations),
      restrictedChats: _sort(restricted),
    );
    await LocalDb.instance.applyChatState(conversationId, isRestricted: false);
  }

  void onNewMessage({
    required String conversationId,
    required String preview,
    required DateTime lastMessageAt,
    bool isIncoming = false,
  }) {
    final readWhileOpen = isIncoming && _activeConversationId == conversationId;
    void update(List<Conversation> list) {
      final idx = list.indexWhere((c) => c.id == conversationId);
      if (idx == -1) return;
      final current = list[idx];
      if (isIncoming &&
          current.lastMessageAt != null &&
          !current.lastMessageAt!.isBefore(lastMessageAt)) {
        return;
      }
      list[idx] = current.copyWith(
        lastMessagePreview: preview,
        lastMessageAt: lastMessageAt,
        unreadCount: isIncoming && !readWhileOpen
            ? current.unreadCount + 1
            : current.unreadCount,
        lastMessageIsMine: !isIncoming,
      );
    }

    final conversations = [...state.conversations];
    update(conversations);
    state = state.copyWith(conversations: _sort(conversations));

    final restricted = [...state.restrictedChats];
    update(restricted);
    state = state.copyWith(restrictedChats: _sort(restricted));

    final blocked = [...state.blockedChats];
    update(blocked);
    state = state.copyWith(blockedChats: _sort(blocked));

    LocalDb.instance.updateConversationPreview(
      conversationId,
      preview: preview,
      lastMessageAt: lastMessageAt.millisecondsSinceEpoch,
      unreadDelta: isIncoming && !readWhileOpen ? 1 : 0,
    );
  }

  Conversation? _findConversation(String conversationId) {
    for (final list in [
      state.conversations,
      state.restrictedChats,
      state.blockedChats,
    ]) {
      for (final conversation in list) {
        if (conversation.id == conversationId) return conversation;
      }
    }
    return null;
  }

  /// Marks [conversationId] as on screen so incoming messages are counted as
  /// already read, and clears any pending badge for it.
  void setActiveConversation(String conversationId) {
    _activeConversationId = conversationId;
    markRead(conversationId);
  }

  void clearActiveConversation(String conversationId) {
    if (_activeConversationId == conversationId) {
      _activeConversationId = null;
    }
  }

  void markRead(String conversationId) {
    bool cleared = false;
    List<Conversation> zeroed(List<Conversation> list) {
      final idx = list.indexWhere((c) => c.id == conversationId);
      if (idx == -1 || list[idx].unreadCount == 0) return list;
      final next = [...list];
      next[idx] = next[idx].copyWith(unreadCount: 0);
      cleared = true;
      return next;
    }

    final conversations = zeroed(state.conversations);
    final restricted = zeroed(state.restrictedChats);
    final blocked = zeroed(state.blockedChats);
    if (!cleared) return;
    state = state.copyWith(
      conversations: conversations,
      restrictedChats: restricted,
      blockedChats: blocked,
    );
    LocalDb.instance.clearUnreadCount(conversationId);
  }

  /// Records that the other user saw my messages up to [seenAt].
  void markPeerSeen(String conversationId, DateTime seenAt) {
    bool touched = false;
    List<Conversation> update(List<Conversation> list) {
      final idx = list.indexWhere((c) => c.id == conversationId);
      if (idx == -1) return list;
      if (_laterOf(list[idx].peerSeenAt, seenAt) == list[idx].peerSeenAt) {
        return list;
      }
      final next = [...list];
      next[idx] = next[idx].copyWith(peerSeenAt: seenAt);
      touched = true;
      return next;
    }

    final conversations = update(state.conversations);
    final restricted = update(state.restrictedChats);
    final blocked = update(state.blockedChats);
    if (!touched) return;
    state = state.copyWith(
      conversations: conversations,
      restrictedChats: restricted,
      blockedChats: blocked,
    );
  }

  void updateRequestCount(int count) {
    state = state.copyWith(requestCount: count);
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
      };
}

final chatsProvider = StateNotifierProvider<ChatsNotifier, ChatsState>((ref) {
  final api = ref.watch(apiServiceProvider);
  final notifier = ChatsNotifier(api);
  ref.onDispose(notifier.dispose);
  return notifier;
});
