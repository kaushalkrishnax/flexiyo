import 'dart:async';

import 'package:flexiyo/models/conversation.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/providers/chat_provider.dart';
import 'package:flexiyo/providers/signal_crypto_provider.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/widgets/avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class MessageRequestsScreen extends ConsumerStatefulWidget {
  const MessageRequestsScreen({super.key});

  @override
  ConsumerState<MessageRequestsScreen> createState() =>
      _MessageRequestsScreenState();
}

class _MessageRequestsScreenState extends ConsumerState<MessageRequestsScreen> {
  List<Conversation> _requests = const [];
  final Set<String> _responding = {};
  bool _loading = true;
  bool _loadInFlight = false;
  String? _error;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadRequests());
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && !_loadInFlight) unawaited(_loadRequests());
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadRequests() async {
    if (_loadInFlight) return;
    _loadInFlight = true;
    setState(() {
      _loading = _requests.isEmpty;
      _error = null;
    });

    try {
      final api = ref.read(apiServiceProvider);
      final userId = ref.read(authProvider).user?.id;
      if (userId == null) throw StateError('Your account is still loading');
      final requests = await api.getMessageRequests();

      final crypto = await ref.read(signalCryptoProvider(userId).future);
      final hydrated = <Conversation>[];

      for (final request in requests) {
        var preview = 'Encrypted message';
        try {
          final messages = await api.getMessages(request.id, limit: 1);
          if (messages.isNotEmpty) {
            final message = messages.first;
            if (message.isUnsent) {
              preview = 'Message unsent';
            } else if (message.encryptedPayload != null) {
              preview = await crypto.getLocalMessageText(message.id) ??
                  await crypto.decryptFromUser(
                    senderId: message.senderId,
                    payload: message.encryptedPayload!,
                    messageType: message.messageType.name,
                  );
              await crypto.saveLocalMessageText(message.id, preview);
            }
          }
        } catch (_) {
          preview = request.lastMessagePreview ?? 'Encrypted message';
        }
        hydrated.add(request.copyWith(lastMessagePreview: preview));
      }

      if (mounted) setState(() => _requests = hydrated);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      _loadInFlight = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _respond(Conversation request, {required bool accept}) async {
    setState(() => _responding.add(request.id));
    try {
      await ref.read(apiServiceProvider).respondToMessageRequest(
            request.id,
            accept: accept,
          );
      if (accept) {
        await ref.read(chatsProvider.notifier).upsertConversation(
              request.copyWith(requestStatus: 'accepted'),
            );
      }
      await _loadRequests();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _responding.remove(request.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Message Requests'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _loadRequests,
            tooltip: 'Refresh requests',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading && _requests.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _requests.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _loadRequests,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _requests.isEmpty
                  ? const Center(child: Text('No pending requests'))
                  : RefreshIndicator(
                      onRefresh: _loadRequests,
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _requests.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final request = _requests[index];
                          final busy = _responding.contains(request.id);

                          return ListTile(
                            onTap: () => context
                                .go('/chats/${request.id}?request=true'),
                            leading: UserAvatar(
                              username: request.otherUsername,
                              radius: 24,
                            ),
                            title: Text(
                              request.otherUsername,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              request.lastMessagePreview ?? 'Encrypted message',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: busy
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: 'Delete request',
                                        onPressed: () => _respond(request,
                                            accept: false),
                                        icon: Icon(
                                          Icons.close_rounded,
                                          color: colorScheme.error,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Accept request',
                                        onPressed: () => _respond(request,
                                            accept: true),
                                        icon: Icon(
                                          Icons.check_rounded,
                                          color: colorScheme.primary,
                                        ),
                                      ),
                                    ],
                                  ),
                          );
                        },
                      ),
                    ),
    );
  }
}
