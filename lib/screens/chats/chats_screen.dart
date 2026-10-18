import 'dart:async';

import 'package:flexiyo/core/app_version.dart';
import 'package:flexiyo/core/seen_status.dart';
import 'package:flexiyo/models/conversation.dart';
import 'package:flexiyo/models/user.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/providers/chat/chat_provider.dart';
import 'package:flexiyo/providers/signal_crypto_provider.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/widgets/conversation/avatar.dart';
import 'package:flexiyo/widgets/conversation/app_popup_menu.dart';
import 'package:flexiyo/widgets/auth/auth_text_field.dart';
import 'package:flexiyo/widgets/confirm_popup.dart';
import 'package:flexiyo/widgets/conversation/skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:intl/intl.dart';

class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen>
    with WidgetsBindingObserver {
  String? _cryptoWarmupUserId;
  String _selectedTab = 'recents';
  String _searchQuery = '';
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  List<User> _userResults = const [];
  bool _searchingUsers = false;
  bool _openingChat = false;
  Timer? _userSearchDebounce;
  int _userSearchSeq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(chatsProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _userSearchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      ref.read(chatsProvider.notifier).load(forceRefresh: true);
    }
  }

  void _onSearchChanged(String value) {
    setState(() => _searchQuery = value);

    final query = value.trim();
    _userSearchDebounce?.cancel();
    if (query.isEmpty) {
      _userSearchSeq++;
      setState(() {
        _userResults = const [];
        _searchingUsers = false;
      });
      return;
    }

    setState(() => _searchingUsers = true);
    _userSearchDebounce = Timer(
      const Duration(milliseconds: 280),
      () => _searchUsers(query),
    );
  }

  Future<void> _searchUsers(String query) async {
    final seq = ++_userSearchSeq;
    try {
      final users = await ref.read(apiServiceProvider).searchUsers(query);
      if (!mounted || seq != _userSearchSeq) return;
      setState(() {
        _userResults = users;
        _searchingUsers = false;
      });
    } catch (_) {
      if (!mounted || seq != _userSearchSeq) return;
      setState(() {
        _userResults = const [];
        _searchingUsers = false;
      });
    }
  }

  Future<void> _openUser(User user) async {
    if (_openingChat) return;
    _openingChat = true;
    try {
      final service = ref.read(apiServiceProvider);
      final conversation = await service.getOrCreateConversation(user.id);
      await ref.read(chatsProvider.notifier).upsertConversation(conversation);
      if (!mounted) return;
      final currentUserId = ref.read(authProvider).user?.id;
      final isIncomingRequest = conversation.requestStatus == 'pending' &&
          conversation.initiatedById != currentUserId;
      context.go(
        '/chats/${conversation.id}${isIncomingRequest ? '?request=true' : ''}',
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start chat: $error')),
      );
    } finally {
      _openingChat = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final chatsState = ref.watch(chatsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final userId = authState.user?.id;

    if (userId != null && userId != _cryptoWarmupUserId) {
      _cryptoWarmupUserId = userId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_warmUpCrypto(userId));
      });
    }

    final totalUnread = chatsState.conversations.fold<int>(
      0,
      (sum, conv) => sum + conv.unreadCount,
    );
    final hasActivityBadge = totalUnread > 0 || chatsState.requestCount > 0;

    final conversations = chatsState.conversations.where((conv) {
      if (_searchQuery.isEmpty) return true;
      return conv.otherUsername
          .toLowerCase()
          .contains(_searchQuery.toLowerCase());
    }).toList();

    final isSearching = _searchQuery.trim().isNotEmpty;
    final friendIds = {for (final conv in conversations) conv.otherUserId};
    final userResults = isSearching
        ? _userResults
            .where((user) => user.id != userId && !friendIds.contains(user.id))
            .toList()
        : const <User>[];

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () =>
              ref.read(chatsProvider.notifier).load(forceRefresh: true),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: SizedBox(
                    height: 44,
                    child: Row(
                      children: [
                        if (context.canPop()) ...[
                          IconButton(
                            onPressed: () => context.pop(),
                            icon: const HugeIcon(
                                icon: HugeIcons.strokeRoundedArrowLeft01),
                            visualDensity: VisualDensity.compact,
                          ),
                          const SizedBox(width: 4),
                        ],
                        ClipRRect(
                          borderRadius: BorderRadius.circular(9),
                          child: Image.asset(
                            'assets/images/app_icon.png',
                            width: 32,
                            height: 32,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Text(
                                'Flexiyo',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 20,
                                      letterSpacing: -0.45,
                                    ),
                              ),
                              const SizedBox(width: 5),
                              Transform.translate(
                                offset: const Offset(0, 4),
                                child: Text(
                                  'v$appVersion',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w500,
                                      ),
                                ),
                              ),
                              if (hasActivityBadge) ...[
                                const SizedBox(width: 7),
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFFF3040),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => context.go('/settings'),
                          icon: const HugeIcon(
                              icon: HugeIcons.strokeRoundedSettings01),
                          tooltip: 'Settings',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                  child: _ChatSearchBar(
                    controller: _searchController,
                    focusNode: _searchFocus,
                    onChanged: _onSearchChanged,
                  ),
                ),
              ),
              if (_searchQuery.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _NotesRail(
                      myUsername: authState.user?.username ?? 'You',
                      conversations: chatsState.conversations,
                      onSelectConversation: (conv) =>
                          context.go('/chats/${conv.id}'),
                    ),
                  ),
                ),
              if (_searchQuery.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                    child: Row(
                      children: [
                        _FilterTab(
                          label: 'Recents',
                          isSelected: _selectedTab == 'recents',
                          onTap: () => setState(() => _selectedTab = 'recents'),
                        ),
                        const SizedBox(width: 24),
                        _FilterTab(
                          label: 'Personal',
                          isSelected: _selectedTab == 'personal',
                          onTap: () =>
                              setState(() => _selectedTab = 'personal'),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => context.go('/chats/requests'),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Requests',
                                style: TextStyle(
                                  color: const Color(0xFF0095F6),
                                  fontWeight: chatsState.requestCount > 0
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                              if (chatsState.requestCount > 0) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0095F6),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    '${chatsState.requestCount}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (authState.user == null ||
                  (!chatsState.hasLoaded &&
                      chatsState.conversations.isEmpty &&
                      chatsState.restrictedChats.isEmpty))
                // Skeleton mirrors the exact tile layout — no spinners.
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: ChatsSkeletonList(),
                )
              else if (chatsState.error != null &&
                  chatsState.conversations.isEmpty)
                SliverFillRemaining(
                  child: _ErrorState(
                    message: chatsState.error!,
                    onRetry: () => ref
                        .read(chatsProvider.notifier)
                        .load(forceRefresh: true),
                  ),
                )
              else if (isSearching)
                ..._searchSlivers(
                  context,
                  conversations,
                  userResults,
                  userId: userId,
                  isDark: isDark,
                )
              else if (conversations.isEmpty)
                SliverFillRemaining(
                  child: _EmptyState(
                    onSearchTapped: () => _searchFocus.requestFocus(),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _chatTile(
                      context,
                      conversations[index],
                      userId: userId,
                      isDark: isDark,
                    ),
                    childCount: conversations.length,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chatTile(
    BuildContext context,
    Conversation conv, {
    required String? userId,
    required bool isDark,
  }) {
    return _ChatTile(
      conversation: conv,
      currentUserId: userId,
      isDark: isDark,
      onTap: () => context.go('/chats/${conv.id}'),
      onLongPress: () {
        AppPopupMenu.showInboxModal(
          context,
          conversation: conv,
          onTogglePin: () =>
              ref.read(chatsProvider.notifier).togglePin(conv.id),
          onToggleMute: () =>
              ref.read(chatsProvider.notifier).toggleMute(conv.id),
          onToggleRestrict: () =>
              ref.read(chatsProvider.notifier).toggleRestrict(conv.id),
          onToggleBlock: () =>
              ref.read(chatsProvider.notifier).toggleBlock(conv.id),
          onSetDisappearingTimer: () => _pickDisappearingTimer(conv),
          onDelete: () => _confirmDeleteConversation(conv.id),
        );
      },
    );
  }

  Future<void> _pickDisappearingTimer(Conversation conversation) async {
    final seconds = await AppPopupMenu.showDisappearingTimerPicker(
      context,
      currentSeconds: conversation.disappearingTimer,
    );
    if (seconds == null || !mounted) return;

    try {
      await ref
          .read(chatsProvider.notifier)
          .updateDisappearingTimer(conversation.id, seconds);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Could not update disappearing messages: $error')),
      );
    }
  }

  Future<void> _confirmDeleteConversation(String conversationId) async {
    final confirmed = await ConfirmPopup.show(
      context,
      title: 'Delete conversation?',
      message: 'Remove this conversation and its messages from your inbox?',
      confirmLabel: 'Delete',
      cancelLabel: 'Cancel',
    );
    if (!confirmed || !mounted) return;
    await ref.read(chatsProvider.notifier).removeConversation(conversationId);
  }

  /// Friends first, then matching accounts that are not in the inbox yet.
  List<Widget> _searchSlivers(
    BuildContext context,
    List<Conversation> friends,
    List<User> results, {
    required String? userId,
    required bool isDark,
  }) {
    final slivers = <Widget>[];

    if (friends.isNotEmpty) {
      slivers
        ..add(const SliverToBoxAdapter(child: _SearchSectionHeader('Friends')))
        ..add(
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _chatTile(
                context,
                friends[index],
                userId: userId,
                isDark: isDark,
              ),
              childCount: friends.length,
            ),
          ),
        );
    }

    if (results.isNotEmpty) {
      slivers
        ..add(const SliverToBoxAdapter(
          child: _SearchSectionHeader('Search Results'),
        ))
        ..add(
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _UserTile(
                user: results[index],
                onTap: () => _openUser(results[index]),
              ),
              childCount: results.length,
            ),
          ),
        );
    }

    if (slivers.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 36, 16, 16),
            child: Center(
              child: Text(
                _searchingUsers
                    ? 'Searching…'
                    : 'No users found for "${_searchQuery.trim()}"',
                style: const TextStyle(color: Colors.grey),
              ),
            ),
          ),
        ),
      );
    }

    return slivers;
  }

  Future<void> _warmUpCrypto(String userId) async {
    try {
      await ref.read(signalCryptoProvider(userId).future);
    } catch (_) {}
  }
}

class _ChatSearchBar extends StatefulWidget {
  const _ChatSearchBar({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;

  @override
  State<_ChatSearchBar> createState() => _ChatSearchBarState();
}

class _ChatSearchBarState extends State<_ChatSearchBar> {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark ? const Color(0xFF262626) : const Color(0xFFEFEFEF);

    return AuthTextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      labelType: AuthTextFieldLabelType.none,
      hintText: 'Search',
      height: 38,
      boxColor: fill,
      borderColor: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      leading: const HugeIcon(
        icon: HugeIcons.strokeRoundedSearch01,
        color: Color(0xFF8E8E93),
        size: 20,
      ),
      trailing: widget.controller.text.isNotEmpty
          ? GestureDetector(
              onTap: () {
                widget.controller.clear();
                widget.onChanged('');
                setState(() {});
              },
              child: const HugeIcon(
                icon: HugeIcons.strokeRoundedCancel01,
                color: Color(0xFF8E8E93),
                size: 16,
              ),
            )
          : null,
      onChanged: (val) {
        widget.onChanged(val);
        setState(() {});
      },
    );
  }
}

/// Section label used while searching: "Friends" vs "Search Results".
class _SearchSectionHeader extends StatelessWidget {
  const _SearchSectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: isDark ? Colors.white60 : Colors.black54,
        ),
      ),
    );
  }
}

/// Account that is not in the inbox yet; tapping starts the conversation.
class _UserTile extends StatelessWidget {
  const _UserTile({required this.user, required this.onTap});

  final User user;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: [
            UserAvatar(username: user.username, radius: 24),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    user.username,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Start a new chat',
                    style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
            HugeIcon(
              icon: HugeIcons.strokeRoundedBubbleChat,
              size: 20,
              color: Colors.grey[500],
            ),
          ],
        ),
      ),
    );
  }
}

class _NotesRail extends StatelessWidget {
  const _NotesRail({
    required this.myUsername,
    required this.conversations,
    required this.onSelectConversation,
  });

  final String myUsername;
  final List<Conversation> conversations;
  final ValueChanged<Conversation> onSelectConversation;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labelColor = isDark ? Colors.white70 : Colors.black87;

    return SizedBox(
      height: 104,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: 1 + conversations.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          if (index == 0) {
            return SizedBox(
              width: 72,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      UserAvatar(username: myUsername, radius: 29),
                      Positioned(
                        top: -3,
                        left: -3,
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color:
                                isDark ? const Color(0xFF333333) : Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.15),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          child: HugeIcon(
                            icon: HugeIcons.strokeRoundedAdd01,
                            size: 16,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Your note',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white54 : Colors.black45,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          final conv = conversations[index - 1];
          final hasUnread = conv.unreadCount > 0;

          return GestureDetector(
            onTap: () => onSelectConversation(conv),
            child: SizedBox(
              width: 72,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  UserAvatar(username: conv.otherUsername, radius: 29),
                  const SizedBox(height: 6),
                  Text(
                    conv.otherUsername,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w400,
                      color: labelColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FilterTab extends StatelessWidget {
  const _FilterTab({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeColor = isDark ? Colors.white : Colors.black;
    final inactiveColor = isDark ? Colors.white54 : Colors.black45;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              color: isSelected ? activeColor : inactiveColor,
            ),
          ),
          const SizedBox(height: 4),
          if (isSelected)
            Container(
              height: 2,
              width: 32,
              decoration: BoxDecoration(
                color: activeColor,
                borderRadius: BorderRadius.circular(2),
              ),
            )
          else
            const SizedBox(height: 2),
        ],
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({
    required this.conversation,
    required this.currentUserId,
    required this.isDark,
    required this.onTap,
    this.onLongPress,
  });

  final Conversation conversation;
  final String? currentUserId;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  String _formatSubtitleTimestamp(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final local = dt.toLocal();
    final diff = now.difference(local);

    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return DateFormat('MMM d').format(local);
  }

  @override
  Widget build(BuildContext context) {
    final hasUnread = conversation.unreadCount > 0;
    final isRequestSent = conversation.requestStatus == 'pending' &&
        conversation.initiatedById == currentUserId;
    final preview = conversation.lastMessagePreview;
    final timestamp = _formatSubtitleTimestamp(conversation.lastMessageAt);

    // Read receipt replaces the preview while my newest message is the last
    // one and the conversant has already seen it.
    final peerSeenAt = conversation.peerSeenAt;
    final lastMessageAt = conversation.lastMessageAt;
    final isSeen = !hasUnread &&
        !isRequestSent &&
        conversation.lastMessageIsMine &&
        peerSeenAt != null &&
        (lastMessageAt == null || !peerSeenAt.isBefore(lastMessageAt));

    final String rawSubtitle;
    if (isRequestSent) {
      rawSubtitle = 'Request sent';
    } else if (hasUnread) {
      if (conversation.unreadCount >= 4) {
        rawSubtitle = '4+ new messages';
      } else if (conversation.unreadCount == 3) {
        rawSubtitle = '3 new messages';
      } else if (conversation.unreadCount == 2) {
        rawSubtitle = '2 new messages';
      } else {
        rawSubtitle = preview != null && preview != 'Encrypted message'
            ? preview
            : 'Sent a message';
      }
    } else if (isSeen) {
      rawSubtitle = seenStatusLabel(peerSeenAt);
    } else if (preview != null && preview != 'Encrypted message') {
      rawSubtitle = preview;
    } else if (conversation.lastMessageAt != null) {
      rawSubtitle = 'Sent a message';
    } else {
      rawSubtitle = 'New conversation';
    }

    // Preview carries the readable content; the timestamp trails dimmed.
    final nameColor = isDark ? Colors.white : Colors.black;
    final previewColor = hasUnread
        ? (isDark ? Colors.white : Colors.black87)
        : Colors.grey[500]!;
    final timingColor = Colors.grey[500]!;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: [
            UserAvatar(
              username: conversation.otherUsername,
              radius: 28,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          conversation.otherUsername,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: nameColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  RichText(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      style: DefaultTextStyle.of(context).style,
                      children: [
                        TextSpan(
                          text: rawSubtitle,
                          style: TextStyle(
                            fontSize: 14,
                            color: previewColor,
                            fontWeight:
                                hasUnread ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                        if (timestamp.isNotEmpty)
                          TextSpan(
                            text: '  ·  $timestamp',
                            style: TextStyle(
                              fontSize: 13,
                              color: timingColor,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (conversation.isMuted) ...[
              const SizedBox(width: 6),
              HugeIcon(
                icon: HugeIcons.strokeRoundedBellOff,
                size: 13,
                color: isDark ? Colors.white54 : Colors.black45,
              ),
            ],
            if (hasUnread) ...[
              const SizedBox(width: 8),
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFF1572DB),
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onSearchTapped});
  final VoidCallback onSearchTapped;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: HugeIcon(
                icon: HugeIcons.strokeRoundedBubbleChat,
                size: 40,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Your messages',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Search a username to start your first encrypted chat.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onSearchTapped,
              icon: const HugeIcon(icon: HugeIcons.strokeRoundedSearch01),
              label: const Text('Find people to message'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HugeIcon(
              icon: HugeIcons.strokeRoundedWifiOff02,
              size: 40,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            const Text("Couldn't load messages"),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
