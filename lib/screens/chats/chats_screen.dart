import 'dart:async';

import 'package:flexiyo/models/conversation.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/providers/chat_provider.dart';
import 'package:flexiyo/providers/signal_crypto_provider.dart';
import 'package:flexiyo/widgets/avatar.dart';
import 'package:flexiyo/widgets/app_popup_menu.dart';
import 'package:flexiyo/widgets/auth_text_field.dart';
import 'package:flexiyo/widgets/skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:hugeicons/hugeicons.dart';

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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      ref.read(chatsProvider.notifier).load(forceRefresh: true);
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
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (context.canPop())
                          Align(
                            alignment: Alignment.centerLeft,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => context.pop(),
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(Icons.arrow_back, size: 24),
                              ),
                            ),
                          ),
                        Align(
                          alignment: Alignment.center,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => context.go('/settings'),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  authState.user?.username ?? 'Messages',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 20,
                                        letterSpacing: -0.4,
                                      ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  size: 20,
                                  color: colorScheme.onSurface,
                                ),
                                if (hasActivityBadge) ...[
                                  const SizedBox(width: 6),
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
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: IconButton(
                            onPressed: () => context.go('/chats/new'),
                            icon: const HugeIcon(
                              icon: HugeIcons.strokeRoundedMessageAdd01,
                              size: 23,
                            ),
                            tooltip: 'New chat',
                          ),
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
                    onChanged: (val) => setState(() => _searchQuery = val),
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
                  (chatsState.isLoading && chatsState.conversations.isEmpty))
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
              else if (conversations.isEmpty)
                SliverFillRemaining(
                  child: _searchQuery.isNotEmpty
                      ? const Center(
                          child: Text(
                            'No conversations match your search',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      : _EmptyState(
                          onNewChat: () => context.go('/chats/new'),
                        ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final conv = conversations[index];
                      return _ChatTile(
                        conversation: conv,
                        currentUserId: authState.user?.id,
                        isDark: isDark,
                        onTap: () => context.go('/chats/${conv.id}'),
                        onLongPress: () {
                          AppPopupMenu.showInboxModal(
                            context,
                            conversation: conv,
                            onTogglePin: () => ref
                                .read(chatsProvider.notifier)
                                .togglePin(conv.id),
                            onToggleMute: () => ref
                                .read(chatsProvider.notifier)
                                .toggleMute(conv.id),
                            onToggleRestrict: () => ref
                                .read(chatsProvider.notifier)
                                .toggleRestrict(conv.id),
                            onToggleBlock: () => ref
                                .read(chatsProvider.notifier)
                                .toggleBlock(conv.id),
                            onDelete: () => ref
                                .read(chatsProvider.notifier)
                                .removeConversation(conv.id),
                          );
                        },
                      );
                    },
                    childCount: conversations.length,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _warmUpCrypto(String userId) async {
    try {
      await ref.read(signalCryptoProvider(userId).future);
    } catch (_) {}
  }
}

class _ChatSearchBar extends StatefulWidget {
  const _ChatSearchBar({required this.onChanged});
  final ValueChanged<String> onChanged;

  @override
  State<_ChatSearchBar> createState() => _ChatSearchBarState();
}

class _ChatSearchBarState extends State<_ChatSearchBar> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark ? const Color(0xFF262626) : const Color(0xFFEFEFEF);

    return AuthTextField(
      controller: _controller,
      labelType: AuthTextFieldLabelType.none,
      hintText: 'Search',
      height: 38,
      boxColor: fill,
      borderColor: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      leading: const Icon(
        Icons.search_rounded,
        color: Color(0xFF8E8E93),
        size: 20,
      ),
      trailing: _controller.text.isNotEmpty
          ? GestureDetector(
              onTap: () {
                _controller.clear();
                widget.onChanged('');
                setState(() {});
              },
              child: const Icon(
                Icons.cancel,
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
    final surfaceColor = Theme.of(context).colorScheme.surface;
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
                          child: Icon(
                            Icons.add,
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
                  Stack(
                    children: [
                      Container(
                        width: 62,
                        height: 62,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: hasUnread
                              ? const SweepGradient(
                                  colors: [
                                    Color(0xFF833AB4),
                                    Color(0xFFFD1D1D),
                                    Color(0xFFFCAF45),
                                    Color(0xFF833AB4),
                                  ],
                                )
                              : null,
                          border: hasUnread
                              ? null
                              : Border.all(
                                  color: isDark
                                      ? const Color(0xFF333333)
                                      : const Color(0xFFE0E0E0),
                                  width: 1.2,
                                ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(2.5),
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: surfaceColor,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: UserAvatar(
                                username: conv.otherUsername,
                                radius: 26,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 2,
                        right: 2,
                        child: Container(
                          width: 13,
                          height: 13,
                          decoration: BoxDecoration(
                            color: const Color(0xFF25D366),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: surfaceColor,
                              width: 2.2,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
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
    final isUnsent = preview == 'Message unsent';
    final timestamp = _formatSubtitleTimestamp(conversation.lastMessageAt);

    final String rawSubtitle;
    if (isRequestSent) {
      rawSubtitle = 'Request sent';
    } else if (isUnsent) {
      rawSubtitle = 'Message unsent';
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
                            fontStyle:
                                isUnsent ? FontStyle.italic : FontStyle.normal,
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
              Icon(
                Icons.notifications_off_outlined,
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
  const _EmptyState({required this.onNewChat});
  final VoidCallback onNewChat;

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
              child: Icon(
                Icons.chat_bubble_outline_rounded,
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
              'Send private, encrypted messages to your contacts.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onNewChat,
              icon: const Icon(Icons.edit_square),
              label: const Text('Send your first message'),
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
            Icon(
              Icons.wifi_off_rounded,
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
