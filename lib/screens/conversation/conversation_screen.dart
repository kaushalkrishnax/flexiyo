import 'dart:async';

import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/providers/chat_provider.dart';
import 'package:flexiyo/providers/conversation_provider.dart';
import 'package:flexiyo/screens/media/camera_screen.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/services/media_service.dart';
import 'package:flexiyo/widgets/avatar.dart';
import 'package:flexiyo/widgets/app_popup_menu.dart';
import 'package:flexiyo/widgets/date_separator.dart';
import 'package:flexiyo/widgets/media_gallery_sheet.dart';
import 'package:flexiyo/widgets/message_bubble.dart';
import 'package:flexiyo/widgets/skeleton.dart';
import 'package:flexiyo/widgets/typing_indicator.dart';
import 'package:flexiyo/widgets/voice_recorder_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:icon_plus/icon_plus.dart';

class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({
    super.key,
    required this.conversationId,
    this.isMessageRequest = false,
  });

  final String conversationId;
  final bool isMessageRequest;

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  bool _atBottom = true;
  bool _recordingVoice = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initConversation();
    });
  }

  Future<void> _initConversation() async {
    await ref
        .read(conversationProvider(widget.conversationId).notifier)
        .initialize();
    if (mounted) {
      _scrollToBottom(animate: false);
    }
  }

  void _onScroll() {
    final pos = _scrollController.position;
    final isAtBottom = pos.pixels >= pos.maxScrollExtent - 80;
    if (_atBottom != isAtBottom) {
      setState(() => _atBottom = isAtBottom);
    }
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      if (animate) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final state = ref.read(conversationProvider(widget.conversationId));
    if (state.editDraft != null) {
      _messageController.clear();
      await ref
          .read(conversationProvider(widget.conversationId).notifier)
          .editMessage(state.editDraft!.message.id, text);
    } else {
      _messageController.clear();
      await ref
          .read(conversationProvider(widget.conversationId).notifier)
          .sendMessage(text);
      _scrollToBottom();
    }
  }

  void _openCamera() {
    final conv =
        ref.read(conversationProvider(widget.conversationId)).conversation;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CameraScreen(
          conversationId: widget.conversationId,
          otherUsername: conv?.otherUsername,
        ),
      ),
    );
  }

  Future<void> _openGallery() async {
    final bytes = await showMediaGallerySheet(context);
    if (bytes == null || !mounted) return;
    final conv =
        ref.read(conversationProvider(widget.conversationId)).conversation;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CameraScreen(
          conversationId: widget.conversationId,
          initialImage: bytes,
          otherUsername: conv?.otherUsername,
        ),
      ),
    );
  }

  Future<void> _sendMediaEnvelope(
    Uint8List bytes,
    MediaKind kind, {
    ViewPolicy policy = ViewPolicy.unlimited,
    int? durationMs,
  }) async {
    try {
      final service = ref.read(mediaServiceProvider);
      final mediaRef = await service.encryptAndUpload(
        bytes: bytes,
        conversationId: widget.conversationId,
        kind: kind,
        policy: policy,
        durationMs: durationMs,
      );
      await ref
          .read(conversationProvider(widget.conversationId).notifier)
          .sendMessage(mediaRef.toEnvelopeString());
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send media: $e')),
        );
      }
    }
  }

  Future<void> _respondToRequest({required bool accept}) async {
    try {
      await ref.read(apiServiceProvider).respondToMessageRequest(
            widget.conversationId,
            accept: accept,
          );
      await ref
          .read(conversationProvider(widget.conversationId).notifier)
          .updateRequestStatus(accept ? 'accepted' : 'rejected');
      if (accept) {
        await ref.read(chatsProvider.notifier).load(forceRefresh: true);
      }
      if (!mounted) return;
      context.go(accept ? '/chats/${widget.conversationId}' : '/chats');
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update request: $error')),
      );
    }
  }

  void _onUserTyping() {
    ref
        .read(conversationProvider(widget.conversationId).notifier)
        .onUserTyping();
  }

  void _showContextMenu(
    BuildContext context,
    Message message,
    Offset tapPosition,
  ) {
    final myUserId = ref.read(authProvider).user?.id ?? '';
    final isMine = message.senderId == myUserId;
    final notifier =
        ref.read(conversationProvider(widget.conversationId).notifier);

    AppPopupMenu.showMessageMenu(
      context,
      isMine: isMine,
      message: message,
      tapPosition: tapPosition,
      onReply: () {
        notifier.setReplyTo(message);
      },
      onCopy: () {
        if (message.isMedia) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Media messages can't be copied"),
              duration: Duration(seconds: 1),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
        final text = message.decryptedText;
        if (text == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Message text is unavailable on this device')),
          );
          return;
        }
        Clipboard.setData(ClipboardData(text: text));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Copied to clipboard'),
            duration: Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
      onUnsend: isMine ? () => notifier.unsendMessage(message.id) : null,
      onDeleteForMe: () => notifier.deleteForMe(message.id),
      onReact: (emoji) => notifier.reactToMessage(message.id, emoji),
    );
  }

  @override
  Widget build(BuildContext context) {
    final conversationState =
        ref.watch(conversationProvider(widget.conversationId));
    final authState = ref.watch(authProvider);
    final myUserId = authState.user?.id ?? '';
    final colorScheme = Theme.of(context).colorScheme;

    ref.listen(
      conversationProvider(widget.conversationId)
          .select((s) => s.messages.length),
      (prev, next) {
        if (_atBottom && next > (prev ?? 0)) {
          _scrollToBottom();
        }
      },
    );

    final conv = conversationState.conversation;
    final messages = conversationState.messages
        .where((m) => !m.isLocallyDeleted && !m.isExpired)
        .toList();

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: _buildAppBar(context, conversationState, colorScheme),
      body: SafeArea(
        child: conversationState.isLoading && messages.isEmpty
            ? const ConversationSkeleton()
            : Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        GestureDetector(
                          onTap: () {
                            if (conversationState.isSelectionMode) {
                              ref
                                  .read(conversationProvider(
                                          widget.conversationId)
                                      .notifier)
                                  .exitSelectionMode();
                            }
                          },
                          child: ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            itemCount: messages.length +
                                (conversationState.isTyping ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (conversationState.isTyping &&
                                  index == messages.length) {
                                return const Padding(
                                  padding: EdgeInsets.only(bottom: 8),
                                  child: TypingIndicator(),
                                );
                              }

                              final message = messages[index];
                              final isMine = message.senderId == myUserId;

                              final prev =
                                  index > 0 ? messages[index - 1] : null;
                              final next = index < messages.length - 1
                                  ? messages[index + 1]
                                  : null;

                              final sameAsPrev =
                                  prev?.senderId == message.senderId &&
                                      message.createdAt
                                              .difference(prev!.createdAt)
                                              .inMinutes <
                                          3;
                              final sameAsNext =
                                  next?.senderId == message.senderId &&
                                      next!.createdAt
                                              .difference(message.createdAt)
                                              .inMinutes <
                                          3;

                              final isFirst = !sameAsPrev;
                              final isLast = !sameAsNext;

                              final showSeparator = prev == null ||
                                  !_isSameDay(
                                      prev.createdAt, message.createdAt);

                              Message? replyToMsg;
                              if (message.replyToId != null) {
                                try {
                                  replyToMsg = messages.firstWhere(
                                    (m) => m.id == message.replyToId,
                                  );
                                } catch (_) {}
                              }

                              final isSelected = conversationState
                                  .selectedMessageIds
                                  .contains(message.id);

                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (showSeparator)
                                    DateSeparator(date: message.createdAt),
                                  MessageBubble(
                                    message: message,
                                    isMine: isMine,
                                    isFirst: isFirst,
                                    isLast: isLast,
                                    showAvatar: !isMine && isLast,
                                    otherUsername: conv?.otherUsername ?? '',
                                    isSelected: isSelected,
                                    replyToMessage: replyToMsg,
                                    onTap: conversationState.isSelectionMode
                                        ? () => ref
                                            .read(conversationProvider(
                                                    widget.conversationId)
                                                .notifier)
                                            .toggleSelection(message.id)
                                        : (message.status ==
                                                    MessageStatus.failed &&
                                                isMine
                                            ? () => ref
                                                .read(conversationProvider(
                                                        widget.conversationId)
                                                    .notifier)
                                                .retryFailedMessage(message.id)
                                            : null),
                                    onLongPressStart: (details) {
                                      if (conversationState.isSelectionMode) {
                                        ref
                                            .read(conversationProvider(
                                                    widget.conversationId)
                                                .notifier)
                                            .toggleSelection(message.id);
                                      } else if (!message.isUnsent) {
                                        _showContextMenu(
                                          context,
                                          message,
                                          details.globalPosition,
                                        );
                                      }
                                    },
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        if (!_atBottom)
                          Positioned(
                            bottom: 12,
                            right: 12,
                            child: AnimatedScale(
                              scale: _atBottom ? 0 : 1,
                              duration: const Duration(milliseconds: 200),
                              child: FloatingActionButton.small(
                                onPressed: _scrollToBottom,
                                elevation: 2,
                                child: const Icon(
                                    Icons.keyboard_arrow_down_rounded),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (widget.isMessageRequest)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _respondToRequest(accept: false),
                              icon: const Icon(Icons.delete_outline_rounded),
                              label: const Text('Delete request'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _respondToRequest(accept: true),
                              icon: const Icon(Icons.check_rounded),
                              label: const Text('Accept'),
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (conversationState.conversation?.requestStatus ==
                          'pending' &&
                      conversationState.conversation?.initiatedById ==
                          myUserId &&
                      messages.any((m) =>
                          !m.isUnsent && m.status != MessageStatus.failed))
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Request sent. You can message again after it is accepted.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                    )
                  else if (conversationState.conversation?.requestStatus ==
                      'rejected')
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'This message request was declined.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                    )
                  else if (conversationState.isSelectionMode)
                    _SelectionBar(
                      selectedCount:
                          conversationState.selectedMessageIds.length,
                      onCancel: () => ref
                          .read(conversationProvider(widget.conversationId)
                              .notifier)
                          .exitSelectionMode(),
                      onDeleteForMe: () => ref
                          .read(conversationProvider(widget.conversationId)
                              .notifier)
                          .deleteSelectedForMe(),
                    )
                  else if (_recordingVoice)
                    VoiceRecorderBar(
                      onCancel: () => setState(() => _recordingVoice = false),
                      onSend: (bytes, durationMs) async {
                        if (mounted) {
                          setState(() => _recordingVoice = false);
                        }
                        await _sendMediaEnvelope(
                          bytes,
                          MediaKind.voice,
                          durationMs: durationMs,
                        );
                      },
                    )
                  else
                    _ComposerBar(
                      controller: _messageController,
                      conversationId: widget.conversationId,
                      onSend: _sendMessage,
                      onChanged: (_) => _onUserTyping(),
                      isSending: conversationState.isSending,
                      replyTo: conversationState.replyTo,
                      editDraft: conversationState.editDraft,
                      onCameraTap: _openCamera,
                      onGalleryTap: _openGallery,
                      onMicTap: () {
                        setState(() => _recordingVoice = true);
                      },
                      onCancelReply: () => ref
                          .read(conversationProvider(widget.conversationId)
                              .notifier)
                          .clearReplyTo(),
                      onCancelEdit: () {
                        ref
                            .read(conversationProvider(widget.conversationId)
                                .notifier)
                            .clearEditDraft();
                        _messageController.clear();
                      },
                    ),
                ],
              ),
      ),
    );
  }

  AppBar _buildAppBar(
    BuildContext context,
    ConversationState state,
    ColorScheme colorScheme,
  ) {
    final conv = state.conversation;
    final isTyping = state.isTyping;

    return AppBar(
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      leadingWidth: 40,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        onPressed: () => context.pop(),
        tooltip: 'Back',
      ),
      title: conv == null
          // Chat still loading: avatar + name placeholder keeps the header
          // shape without printing throwaway text like "Conversation".
          ? const Row(
              children: [
                SkeletonCircle(size: 36),
                SizedBox(width: 10),
                Expanded(child: SkeletonBox(height: 14)),
              ],
            )
          : Row(
              children: [
                UserAvatar(username: conv.otherUsername, radius: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        conv.otherUsername,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.3,
                                ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        isTyping ? 'typing…' : 'Tap for more info',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: isTyping
                                  ? colorScheme.primary
                                  : colorScheme.onSurfaceVariant,
                              fontStyle: isTyping
                                  ? FontStyle.italic
                                  : FontStyle.normal,
                              fontSize: 11,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
      actions: [
        IconButton(
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Video call not available')),
            );
          },
          icon: const Icon(Icons.videocam_outlined),
          tooltip: 'Video call',
        ),
        IconButton(
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Voice call not available')),
            );
          },
          icon: const Icon(Icons.phone_outlined),
          tooltip: 'Voice call',
        ),
      ],
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    final la = a.toLocal();
    final lb = b.toLocal();
    return la.year == lb.year && la.month == lb.month && la.day == lb.day;
  }
}

class _ComposerBar extends ConsumerWidget {
  const _ComposerBar({
    required this.controller,
    required this.conversationId,
    required this.onSend,
    required this.onChanged,
    required this.isSending,
    required this.replyTo,
    required this.editDraft,
    required this.onCameraTap,
    required this.onGalleryTap,
    required this.onMicTap,
    required this.onCancelReply,
    required this.onCancelEdit,
  });

  final TextEditingController controller;
  final String conversationId;
  final VoidCallback onSend;
  final ValueChanged<String> onChanged;
  final bool isSending;
  final Message? replyTo;
  final EditDraft? editDraft;
  final VoidCallback onCameraTap;
  final VoidCallback onGalleryTap;
  final VoidCallback onMicTap;
  final VoidCallback onCancelReply;
  final VoidCallback onCancelEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final capsuleBg =
        isDark ? const Color(0xFF262626) : const Color(0xFFEFEFEF);
    const brandBlue = Color(0xFF0095F6);

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: colorScheme.outlineVariant.withAlpha(50),
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyTo != null)
              _ReplyBanner(
                message: replyTo!,
                onDismiss: onCancelReply,
                colorScheme: colorScheme,
              ),
            if (editDraft != null)
              _EditBanner(
                originalText: editDraft!.text,
                onDismiss: onCancelEdit,
                colorScheme: colorScheme,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) {
                  final hasText = value.text.trim().isNotEmpty;
                  final isMultiline =
                      value.text.contains('\n') || value.text.length > 40;

                  // Single capsule: text field + app bar-free icon row.
                  // While typing, every affordance collapses into one send
                  // action; while idle, camera / gallery / voice show through.
                  return Row(
                    crossAxisAlignment: isMultiline
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 44),
                          decoration: BoxDecoration(
                            color: capsuleBg,
                            borderRadius: BorderRadius.circular(
                              isMultiline ? 12 : 24,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: isMultiline
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.center,
                            children: [
                              if (!hasText) ...[
                                _ComposerIconButton(
                                  icon: IonIcons.camera,
                                  color: isDark ? Colors.white : Colors.black,
                                  tooltip: 'Camera',
                                  onTap: onCameraTap,
                                ),
                              ] else ...[
                                _ComposerIconButton(
                                  icon: IonIcons.send,
                                  color: Colors.white,
                                  forceBackgroundColor: brandBlue,
                                  tooltip:
                                      editDraft != null ? 'Update' : 'Send',
                                  onTap: onSend,
                                ),
                              ],

                              Expanded(
                                child: Theme(
                                  data: Theme.of(context).copyWith(
                                    inputDecorationTheme:
                                        const InputDecorationTheme(
                                      filled: false,
                                      fillColor: Colors.transparent,
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      disabledBorder: InputBorder.none,
                                      errorBorder: InputBorder.none,
                                      focusedErrorBorder: InputBorder.none,
                                    ),
                                  ),
                                  child: TextField(
                                    controller: controller,
                                    onChanged: onChanged,
                                    onSubmitted: (_) => onSend(),
                                    minLines: 1,
                                    maxLines: 5,
                                    textInputAction: TextInputAction.newline,
                                    keyboardType: TextInputType.multiline,
                                    style: TextStyle(
                                      fontSize: 15,
                                      color:
                                          isDark ? Colors.white : Colors.black,
                                    ),
                                    decoration: InputDecoration(
                                      hintText: editDraft != null
                                          ? 'Edit message…'
                                          : 'Message…',
                                      hintStyle: TextStyle(
                                        fontSize: 15,
                                        color: isDark
                                            ? Colors.white38
                                            : Colors.black38,
                                      ),
                                      filled: false,
                                      fillColor: Colors.transparent,
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      disabledBorder: InputBorder.none,
                                      errorBorder: InputBorder.none,
                                      focusedErrorBorder: InputBorder.none,
                                      isDense: true,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              vertical: 11),
                                    ),
                                  ),
                                ),
                              ),

                              // Right affordances: gallery + voice note. Both
                              // disappear the moment typing starts.
                              if (!hasText) ...[
                                _ComposerIconButton(
                                  icon: IonIcons.image,
                                  color: isDark ? Colors.white : Colors.black,
                                  tooltip: 'Gallery',
                                  onTap: onGalleryTap,
                                ),
                                _ComposerIconButton(
                                  icon: Iconsax.microphone_2_outline,
                                  color: isDark ? Colors.white : Colors.black,
                                  tooltip: 'Voice note',
                                  onTap: onMicTap,
                                ),
                              ] else ...[
                                if (isSending) ...[
                                  const Padding(
                                    padding:
                                        EdgeInsets.symmetric(horizontal: 6),
                                    child: SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: brandBlue,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 44px tap-target icon button inside the composer capsule.
class _ComposerIconButton extends StatelessWidget {
  const _ComposerIconButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
    this.forceBackgroundColor,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  final Color? forceBackgroundColor;

  @override
  Widget build(BuildContext context) {
    final inline = forceBackgroundColor != null;
    return Padding(
      padding: EdgeInsets.only(
        left: inline ? 5 : 2,
        right: 4,
        top: 3,
        bottom: 3,
      ),
      child: Material(
        color: forceBackgroundColor ?? Colors.transparent,
        shape: inline ? const CircleBorder() : null,
        child: IconButton(
          icon: Icon(icon, size: 22, color: color),
          padding: EdgeInsets.zero,
          tooltip: tooltip,
          style: IconButton.styleFrom(
            splashFactory: NoSplash.splashFactory,
          ),
          constraints: const BoxConstraints(minWidth: 34, minHeight: 38),
          onPressed: onTap,
        ),
      ),
    );
  }
}

class _ReplyBanner extends StatelessWidget {
  const _ReplyBanner({
    required this.message,
    required this.onDismiss,
    required this.colorScheme,
  });

  final Message message;
  final VoidCallback onDismiss;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final text = message.mediaRef?.label ??
        message.decryptedText ??
        message.encryptedPayload ??
        'Message';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(
          left: BorderSide(color: colorScheme.primary, width: 3),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.reply_rounded, size: 16, color: colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Replying',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                  ),
                ),
                Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 16),
            onPressed: onDismiss,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }
}

class _EditBanner extends StatelessWidget {
  const _EditBanner({
    required this.originalText,
    required this.onDismiss,
    required this.colorScheme,
  });

  final String originalText;
  final VoidCallback onDismiss;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(
          left: BorderSide(color: colorScheme.tertiary, width: 3),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.edit_rounded, size: 16, color: colorScheme.tertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Editing',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.tertiary,
                  ),
                ),
                Text(
                  originalText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13, color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 16),
            onPressed: onDismiss,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.selectedCount,
    required this.onCancel,
    required this.onDeleteForMe,
  });

  final int selectedCount;
  final VoidCallback onCancel;
  final VoidCallback onDeleteForMe;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      color: colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close_rounded),
              onPressed: onCancel,
              tooltip: 'Cancel',
            ),
            Expanded(
              child: Text(
                '$selectedCount selected',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            TextButton.icon(
              onPressed: selectedCount > 0 ? onDeleteForMe : null,
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Delete for me'),
              style: TextButton.styleFrom(
                foregroundColor: colorScheme.error,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
