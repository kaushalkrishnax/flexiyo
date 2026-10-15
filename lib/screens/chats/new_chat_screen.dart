import 'package:flexiyo/models/user.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/providers/chat_provider.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/widgets/auth_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key});

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  final _searchController = TextEditingController();
  bool _searching = false;
  List<User> _results = const [];
  String? _error;

  Future<void> _searchUsers() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _error = null;
      });
      return;
    }

    setState(() {
      _searching = true;
      _error = null;
    });

    try {
      final service = ref.read(apiServiceProvider);
      final users = await service.searchUsers(query);
      if (!mounted) return;
      setState(() {
        _results = users;
        _searching = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _searching = false;
      });
    }
  }

  Future<void> _startConversation(User user) async {
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New chat')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              AuthTextField(
                controller: _searchController,
                label: 'Search username',
                labelType: AuthTextFieldLabelType.floating,
                leading: const Icon(Icons.search_rounded, size: 22, color: Color(0xFF8E8E93)),
                trailing: IconButton(
                  icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                  onPressed: _searchUsers,
                ),
                onSubmitted: (_) => _searchUsers(),
              ),
              const SizedBox(height: 16),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              Expanded(
                child: _searching
                    ? const Center(child: CircularProgressIndicator())
                    : _results.isEmpty
                        ? const Center(
                            child: Text(
                                'Search for a username to start a secure chat.'),
                          )
                        : ListView.separated(
                            itemCount: _results.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final user = _results[index];
                              return Card(
                                child: ListTile(
                                  leading: CircleAvatar(
                                    child: Text(user.username
                                        .substring(0, 1)
                                        .toUpperCase()),
                                  ),
                                  title: Text(user.username),
                                  subtitle:
                                      const Text('Tap to start a conversation'),
                                  onTap: () => _startConversation(user),
                                ),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
