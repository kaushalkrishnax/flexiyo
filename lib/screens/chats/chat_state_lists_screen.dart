import 'package:flexiyo/models/conversation.dart';
import 'package:flexiyo/providers/chat_provider.dart';
import 'package:flexiyo/widgets/avatar.dart';
import 'package:flexiyo/widgets/skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class RestrictedChatsScreen extends ConsumerStatefulWidget {
  const RestrictedChatsScreen({super.key});

  @override
  ConsumerState<RestrictedChatsScreen> createState() =>
      _RestrictedChatsScreenState();
}

class _RestrictedChatsScreenState extends ConsumerState<RestrictedChatsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(chatsProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final chatsState = ref.watch(chatsProvider);
    final items = chatsState.restrictedChats;
    return Scaffold(
      appBar: AppBar(title: const Text('Restricted')),
      body: !chatsState.hasLoaded && items.isEmpty
          ? const ChatsSkeletonList(itemCount: 5)
          : items.isEmpty
              ? const Center(child: Text('No restricted chats'))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final conv = items[index];
                    return _StateChatTile(
                      conversation: conv,
                      onTap: () =>
                          context.go('/chats/${conv.id}?browse=restricted'),
                    );
                  },
                ),
    );
  }
}

class BlockedChatsScreen extends ConsumerStatefulWidget {
  const BlockedChatsScreen({super.key});

  @override
  ConsumerState<BlockedChatsScreen> createState() => _BlockedChatsScreenState();
}

class _BlockedChatsScreenState extends ConsumerState<BlockedChatsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(chatsProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final chatsState = ref.watch(chatsProvider);
    final items = chatsState.blockedChats;
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked')),
      body: !chatsState.hasLoaded && items.isEmpty
          ? const ChatsSkeletonList(itemCount: 5)
          : items.isEmpty
              ? const Center(child: Text('No blocked chats'))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final conv = items[index];
                    return _StateChatTile(
                      conversation: conv,
                      onTap: () =>
                          context.go('/chats/${conv.id}?browse=blocked'),
                    );
                  },
                ),
    );
  }
}

class _StateChatTile extends StatelessWidget {
  const _StateChatTile({required this.conversation, required this.onTap});

  final Conversation conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: UserAvatar(username: conversation.otherUsername, radius: 24),
      title: Text(
        conversation.otherUsername,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        conversation.lastMessagePreview ?? 'Encrypted message',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
