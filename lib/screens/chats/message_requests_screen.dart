import 'package:flexiyo/models/conversation.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/providers/chat_provider.dart';
import 'package:flexiyo/providers/signal_crypto_provider.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/widgets/app_popup_menu.dart';
import 'package:flexiyo/widgets/avatar.dart';
import 'package:flexiyo/widgets/skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hugeicons/hugeicons.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadRequests());
  }

  @override
  void dispose() {
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
            if (message.encryptedPayload != null) {
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

      if (mounted) {
        setState(() => _requests = hydrated);
        // Keep the chats-screen badge in sync with what the server returned.
        ref.read(chatsProvider.notifier).updateRequestCount(hydrated.length);
      }
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
          Builder(
            builder: (buttonContext) => IconButton(
              onPressed: () {
                final box = buttonContext.findRenderObject() as RenderBox?;
                final offset = box?.localToGlobal(Offset.zero) ?? Offset.zero;
                final size = box?.size ?? Size.zero;
                showRequestsListsMenu(
                  context,
                  onRestricted: () =>
                      context.go('/chats/requests/restricted'),
                  onBlocked: () =>
                      context.go('/chats/requests/blocked'),
                  position: Rect.fromLTWH(
                    offset.dx,
                    offset.dy + size.height,
                    size.width,
                    0,
                  ),
                );
              },
              icon: const HugeIcon(icon: HugeIcons.strokeRoundedMoreVertical),
            ),
          ),
          IconButton(
            onPressed: _loading ? null : _loadRequests,
            tooltip: 'Refresh requests',
            icon: const HugeIcon(icon: HugeIcons.strokeRoundedRefresh),
          ),
        ],
      ),
      body: _loading && _requests.isEmpty
          ? const ChatsSkeletonList(itemCount: 4)
          : _error != null && _requests.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _loadRequests,
                        icon: const HugeIcon(icon: HugeIcons.strokeRoundedRefresh),
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
                                        icon: HugeIcon(
                                          icon: HugeIcons.strokeRoundedCancel01,
                                          color: colorScheme.error,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Accept request',
                                        onPressed: () => _respond(request,
                                            accept: true),
                                        icon: HugeIcon(
                                          icon: HugeIcons.strokeRoundedCheck,
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
