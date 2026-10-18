import 'dart:async';

import 'package:flexiyo/core/image_picker/platform_image_picker.dart';
import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/providers/chat/chat_provider.dart';
import 'package:flexiyo/providers/chat/conversation_provider.dart';
import 'package:flexiyo/screens/media/camera_screen.dart';
import 'package:flexiyo/services/api_service.dart';
import 'package:flexiyo/services/media/media_service.dart';
import 'package:flexiyo/widgets/conversation/avatar.dart';
import 'package:flexiyo/widgets/conversation/app_popup_menu.dart';
import 'package:flexiyo/widgets/conversation/date_separator.dart';
import 'package:flexiyo/widgets/media/media_gallery_sheet.dart';
import 'package:flexiyo/widgets/conversation/message_bubble.dart';
import 'package:flexiyo/widgets/conversation/skeleton.dart';
import 'package:flexiyo/widgets/conversation/typing_indicator.dart';
import 'package:flexiyo/widgets/media/voice_recorder_bar.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hugeicons/hugeicons.dart';

class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({
    super.key,
    required this.conversationId,
    this.isMessageRequest = false,
    this.browseMode,
  });

  final String conversationId;
  final bool isMessageRequest;
  final String? browseMode;

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen>
    with SingleTickerProviderStateMixin {
  final _messageController = TextEditingController();
  final _composerFocus = FocusNode();
  final _scrollController = ScrollController();
  bool _atBottom = true;
  bool _recordingVoice = false;
  late final ChatsNotifier _chatsNotifier;

  /// Distance (logical px) a bubble slides at full swipe travel.
  static const double _swipeMax = kMessageSwipeMaxOffset;

  /// Fraction of the swipe travel that arms the reply action.
  static const double _swipeReplyThreshold = 0.6;

  /// 0 = at rest (icon hidden), 1 = fully swiped. Only the message under the
  /// finger moves; the reply icon fades in on the edge the bubble slides
  /// away from, and everything springs back on release.
  late final AnimationController _swipe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );

  /// Message currently under a swipe gesture.
  String? _swipingId;

  /// Distance (logical px) of right-to-left travel that fully reveals every
  /// timestamp while a message is held.
  static const double _timesRevealDistance = 72;

  /// 0 = timestamps hidden, 1 = fully revealed. Driven by holding a message
  /// and sliding right-to-left; it clamps and springs back on release.
  late final AnimationController _timesReveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  /// Accumulated horizontal travel of an in-progress background peek drag.
  double _timesDragDx = 0;

  @override
  void initState() {
    super.initState();
    _chatsNotifier = ref.read(chatsProvider.notifier);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initConversation();
    });
  }

  /// Runs on drag start. Horizontal bars only count travel since this frame.
  void _onTimesDragStart(DragStartDetails details) {
    _timesDragDx = 0;
    _timesReveal.stop();
    _timesReveal.value = 0;
  }

  void _onTimesDragUpdate(DragUpdateDetails details) {
    _timesDragDx += details.delta.dx;
    _timesReveal.value =
        (-_timesDragDx / _timesRevealDistance).clamp(0.0, 1.0).toDouble();
  }

  void _onMessageSwipeStart(String messageId) {
    if (_swipingId != null) return; // One swipe at a time.
    setState(() => _swipingId = messageId);
  }

  void _onMessageSwipeUpdate(
    DragUpdateDetails details,
    String messageId,
    bool isMine,
  ) {
    if (_swipingId != messageId) return;
    // Own messages slide right-to-left; incoming messages slide left-to-right.
    final delta = isMine ? -details.delta.dx : details.delta.dx;
    if (delta <= 0) return;
    _swipe.value =
        (_swipe.value + delta / _swipeMax).clamp(0.0, 1.0).toDouble();
  }

  /// Pulls the keyboard up so a fresh reply only needs typing.
  void _focusComposer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _composerFocus.requestFocus();
    });
  }

  void _onMessageSwipeEnd(String messageId) {
    final id = _swipingId;
    if (id == null || id != messageId) return;

    if (_swipe.value >= _swipeReplyThreshold) {
      Message? target;
      final messages =
          ref.read(conversationProvider(widget.conversationId)).messages;
      for (final message in messages) {
        if (message.id == id) {
          target = message;
          break;
        }
      }
      if (target != null) {
        HapticFeedback.mediumImpact();
        ref
            .read(conversationProvider(widget.conversationId).notifier)
            .setReplyTo(target);
        _focusComposer();
      }
    }

    if (_swipe.value == 0) {
      setState(() => _swipingId = null);
      return;
    }
    final spring = _swipe.animateTo(
      0,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
    spring.whenCompleteOrCancel(() {
      if (mounted && _swipingId == id) {
        setState(() => _swipingId = null);
      }
    });
  }

  /// Hides the timestamp gutter again; called on every release.
  void _springBackTimes() {
    if (_timesReveal.value == 0) return;
    _timesReveal.animateTo(
      0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  /// Reply arrow that fades in on the edge a bubble slides away from;
  /// brightens once the swipe has travelled far enough to arm the reply.
  Widget _replySwipeIcon(BuildContext context, double t) {
    final cs = Theme.of(context).colorScheme;
    return Transform.scale(
      scale: 0.75 + 0.25 * t,
      child: HugeIcon(
        icon: HugeIcons.strokeRoundedReply,
        size: 20,
        color: t >= _swipeReplyThreshold ? cs.onSurface : cs.onSurfaceVariant,
      ),
    );
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
    _chatsNotifier.clearActiveConversation(widget.conversationId);
    _messageController.dispose();
    _composerFocus.dispose();
    _scrollController.dispose();
    _swipe.dispose();
    _timesReveal.dispose();
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

  Future<void> _openCamera() async {
    final conv =
        ref.read(conversationProvider(widget.conversationId)).conversation;
    // The in-app camera prompts repeatedly on web (once per device plus init
    // setup), so capture through a file input and review in the same screen.
    if (kIsWeb) {
      final bytes = await pickImageBytes(fromCamera: true);
      if (bytes == null || !mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CameraScreen(
            conversationId: widget.conversationId,
            initialImage: bytes,
            otherUsername: conv?.otherUsername,
          ),
        ),
      );
      return;
    }
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
    final result = await showMediaGallerySheet(context);
    if (result == null || !mounted) return;

    // Send keeps the picker flow; Edit opens the image in the preview screen
    // so it can be cropped/drawn on before sending.
    if (!result.edit) {
      await _sendMediaEnvelope(result.bytes, MediaKind.image);
      return;
    }

    final conv =
        ref.read(conversationProvider(widget.conversationId)).conversation;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CameraScreen(
          conversationId: widget.conversationId,
          initialImage: result.bytes,
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
    String? mimeType,
  }) async {
    try {
      final service = ref.read(mediaServiceProvider);
      final mediaRef = await service.encryptAndUpload(
        bytes: bytes,
        conversationId: widget.conversationId,
        kind: kind,
        policy: policy,
        durationMs: durationMs,
        mimeType: mimeType,
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
        _focusComposer();
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
        .where((m) => !m.isLocallyDeleted && !m.isExpired && !m.isUnsent)
        .toList();

    // Banner title for the message being replied to: matches the reference
    // wording, e.g. "Replying to yourself" / "Replying to <username>".
    final replyTo = conversationState.replyTo;
    final replyToTitle = replyTo == null
        ? null
        : replyTo.senderId == myUserId
            ? 'Replying to yourself'
            : 'Replying to ${conv?.otherUsername ?? ''}';

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: _buildAppBar(context, conversationState, colorScheme),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  if (conversationState.isLoading && messages.isEmpty)
                    const Positioned.fill(
                      child: ConversationSkeleton(),
                    ),
                  GestureDetector(
                    onTap: () {
                      if (conversationState.isSelectionMode) {
                        ref
                            .read(conversationProvider(widget.conversationId)
                                .notifier)
                            .exitSelectionMode();
                      }
                    },
                    // A right-to-left drag moves message rows together and
                    // reveals their timestamps in a fixed right-side lane.
                    onHorizontalDragStart: _onTimesDragStart,
                    onHorizontalDragUpdate: _onTimesDragUpdate,
                    onHorizontalDragEnd: (_) => _springBackTimes(),
                    onHorizontalDragCancel: _springBackTimes,
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

                        final prev = index > 0 ? messages[index - 1] : null;
                        final next = index < messages.length - 1
                            ? messages[index + 1]
                            : null;

                        final sameAsPrev = prev?.senderId == message.senderId &&
                            message.createdAt
                                    .difference(prev!.createdAt)
                                    .inMinutes <
                                3;
                        final sameAsNext = next?.senderId == message.senderId &&
                            next!.createdAt
                                    .difference(message.createdAt)
                                    .inMinutes <
                                3;

                        final isFirst = !sameAsPrev;
                        final isLast = !sameAsNext;

                        final showSeparator = prev == null ||
                            !_isSameDay(prev.createdAt, message.createdAt);

                        Message? replyToMsg;
                        if (message.replyToId != null) {
                          try {
                            replyToMsg = messages.firstWhere(
                              (m) => m.id == message.replyToId,
                            );
                          } catch (_) {}
                        }

                        final isSelected = conversationState.selectedMessageIds
                            .contains(message.id);

                        final swipeEnabled = !conversationState.isSelectionMode;

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (showSeparator)
                              DateSeparator(date: message.createdAt),
                            // Slide the bubble toward the inside of
                            // the screen (own messages right-to-left,
                            // incoming left-to-right) to fade in the
                            // reply icon and arm a reply; releasing
                            // past the threshold replies, otherwise
                            // everything springs back. Holding a
                            // message and sliding right-to-left peeks
                            // to reveal the chat-wide timestamp lane instead.
                            GestureDetector(
                              behavior: conversationState.isSelectionMode
                                  ? HitTestBehavior.opaque
                                  : HitTestBehavior.deferToChild,
                              onHorizontalDragStart: swipeEnabled
                                  ? (_) => _onMessageSwipeStart(message.id)
                                  : null,
                              onHorizontalDragUpdate: swipeEnabled
                                  ? (details) => _onMessageSwipeUpdate(
                                        details,
                                        message.id,
                                        isMine,
                                      )
                                  : null,
                              onHorizontalDragEnd: swipeEnabled
                                  ? (_) => _onMessageSwipeEnd(message.id)
                                  : null,
                              onHorizontalDragCancel: swipeEnabled
                                  ? () => _onMessageSwipeEnd(message.id)
                                  : null,
                              onLongPressStart: (details) {
                                if (conversationState.isSelectionMode) {
                                  ref
                                      .read(conversationProvider(
                                              widget.conversationId)
                                          .notifier)
                                      .toggleSelection(message.id);
                                } else {
                                  _showContextMenu(
                                    context,
                                    message,
                                    details.globalPosition,
                                  );
                                }
                              },
                              child: AnimatedBuilder(
                                animation: _swipe,
                                child: MessageBubble(
                                  message: message,
                                  isMine: isMine,
                                  isFirst: isFirst,
                                  isLast: isLast,
                                  showAvatar: !isMine && isLast,
                                  otherUsername: conv?.otherUsername ?? '',
                                  isSelected: isSelected,
                                  replyToMessage: replyToMsg,
                                  swipeAnimation: swipeEnabled ? _swipe : null,
                                  swiping: _swipingId == message.id,
                                  timesReveal: _timesReveal,
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
                                ),
                                builder: (context, child) {
                                  final t = _swipingId == message.id
                                      ? _swipe.value
                                      : 0.0;
                                  return Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      // Reply affordance: fades in on
                                      // the edge the bubble slides
                                      // away from. Incoming icons
                                      // surface in the gap between
                                      // the avatar and the bubble.
                                      Positioned.fill(
                                        child: IgnorePointer(
                                          child: Align(
                                            alignment: isMine
                                                ? Alignment.centerRight
                                                : Alignment.centerLeft,
                                            child: Opacity(
                                              opacity: t,
                                              child: Padding(
                                                padding: EdgeInsets.only(
                                                  left: isMine ? 0 : 44,
                                                  right: isMine ? 12 : 0,
                                                ),
                                                child: _replySwipeIcon(
                                                  context,
                                                  t,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      // The bubble itself slides
                                      // inside MessageBubble so
                                      // incoming avatars stay
                                      // anchored; the held timestamp
                                      // peek slides rows toward the shared
                                      // timestamp lane.
                                      child!,
                                    ],
                                  );
                                },
                              ),
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
                          child: const HugeIcon(
                              icon: HugeIcons.strokeRoundedArrowDown01),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (widget.browseMode != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => context.pop(),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () async {
                          final notifier = ref.read(chatsProvider.notifier);
                          if (widget.browseMode == 'restricted') {
                            await notifier.unrestrict(widget.conversationId);
                          } else {
                            await notifier.unblock(widget.conversationId);
                          }
                          if (context.mounted) context.pop();
                        },
                        child: Text(widget.browseMode == 'restricted'
                            ? 'Unrestrict'
                            : 'Unblock'),
                      ),
                    ),
                  ],
                ),
              )
            else if (widget.isMessageRequest)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _respondToRequest(accept: false),
                        icon: const HugeIcon(
                            icon: HugeIcons.strokeRoundedDelete02),
                        label: const Text('Delete request'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _respondToRequest(accept: true),
                        icon:
                            const HugeIcon(icon: HugeIcons.strokeRoundedCheck),
                        label: const Text('Accept'),
                      ),
                    ),
                  ],
                ),
              )
            else if (conversationState.conversation?.requestStatus ==
                    'pending' &&
                conversationState.conversation?.initiatedById == myUserId &&
                messages.any(
                    (m) => !m.isUnsent && m.status != MessageStatus.failed))
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
                selectedCount: conversationState.selectedMessageIds.length,
                onCancel: () => ref
                    .read(conversationProvider(widget.conversationId).notifier)
                    .exitSelectionMode(),
                onDeleteForMe: () => ref
                    .read(conversationProvider(widget.conversationId).notifier)
                    .deleteSelectedForMe(),
              )
            else if (_recordingVoice)
              VoiceRecorderBar(
                onCancel: () => setState(() => _recordingVoice = false),
                onSend: (bytes, durationMs, mimeType) async {
                  if (mounted) {
                    setState(() => _recordingVoice = false);
                  }
                  await _sendMediaEnvelope(
                    bytes,
                    MediaKind.voice,
                    durationMs: durationMs,
                    mimeType: mimeType,
                  );
                },
              )
            else
              _ComposerBar(
                controller: _messageController,
                focusNode: _composerFocus,
                conversationId: widget.conversationId,
                onSend: _sendMessage,
                onChanged: (_) => _onUserTyping(),
                isSending: conversationState.isSending,
                replyTo: conversationState.replyTo,
                replyToTitle: replyToTitle,
                editDraft: conversationState.editDraft,
                onCameraTap: _openCamera,
                onGalleryTap: _openGallery,
                onMicTap: () {
                  setState(() => _recordingVoice = true);
                },
                onCancelReply: () => ref
                    .read(conversationProvider(widget.conversationId).notifier)
                    .clearReplyTo(),
                onCancelEdit: () {
                  ref
                      .read(
                          conversationProvider(widget.conversationId).notifier)
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
        icon:
            const HugeIcon(icon: HugeIcons.strokeRoundedArrowLeft01, size: 20),
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
          icon: const HugeIcon(
            icon: HugeIcons.strokeRoundedVideo01,
            size: 22,
          ),
          tooltip: 'Video call',
        ),
        IconButton(
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Voice call not available')),
            );
          },
          icon: const HugeIcon(
            icon: HugeIcons.strokeRoundedCall,
            size: 22,
          ),
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
    required this.focusNode,
    required this.conversationId,
    required this.onSend,
    required this.onChanged,
    required this.isSending,
    required this.replyTo,
    required this.replyToTitle,
    required this.editDraft,
    required this.onCameraTap,
    required this.onGalleryTap,
    required this.onMicTap,
    required this.onCancelReply,
    required this.onCancelEdit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String conversationId;
  final VoidCallback onSend;
  final ValueChanged<String> onChanged;
  final bool isSending;
  final Message? replyTo;
  final String? replyToTitle;
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
                title: replyToTitle ?? 'Replying',
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

                  // Single full-width capsule: text field with the camera
                  // anchored on the left and the voice-note mic plus the
                  // gallery at its right end (mic first, gallery rightmost).
                  // The camera button stays visible at all times, which also
                  // keeps the text field anchored at a stable position so
                  // it never loses focus (and the keyboard never closes)
                  // when typing starts. Typing swaps mic + gallery for send
                  // in place.
                  return Row(
                    crossAxisAlignment: isMultiline
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 52),
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
                              // Always visible: keeping this at index 0
                              // stops the text field from being recreated
                              // (and losing focus) when typing starts.
                              _ComposerIconButton(
                                icon: HugeIcons.strokeRoundedCamera01,
                                color: Colors.white,
                                forceBackgroundColor: brandBlue,
                                extraRight: 6,
                                tooltip: 'Camera',
                                onTap: onCameraTap,
                              ),
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
                                    focusNode: focusNode,
                                    onChanged: onChanged,
                                    onSubmitted: (_) => onSend(),
                                    minLines: 1,
                                    maxLines: 5,
                                    textInputAction: TextInputAction.newline,
                                    keyboardType: TextInputType.multiline,
                                    style: TextStyle(
                                      fontSize: 16,
                                      color:
                                          isDark ? Colors.white : Colors.black,
                                    ),
                                    decoration: InputDecoration(
                                      hintText: editDraft != null
                                          ? 'Edit message…'
                                          : 'Message…',
                                      hintStyle: TextStyle(
                                        fontSize: 16,
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
                                              vertical: 14),
                                    ),
                                  ),
                                ),
                              ),

                              // Right affordances inside the capsule:
                              // voice note first, then gallery at the
                              // capsule's right end. The moment typing
                              // starts they swap to the send button
                              // (matched in place by Flutter, so the field
                              // above keeps focus).
                              if (!hasText) ...[
                                _ComposerIconButton(
                                  icon: HugeIcons.strokeRoundedMic01,
                                  color: isDark ? Colors.white : Colors.black,
                                  tooltip: 'Voice note',
                                  onTap: onMicTap,
                                ),
                                _ComposerIconButton(
                                  icon: HugeIcons.strokeRoundedImage01,
                                  color: isDark ? Colors.white : Colors.black,
                                  extraRight: 8,
                                  tooltip: 'Gallery',
                                  onTap: onGalleryTap,
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
                                _ComposerIconButton(
                                  icon: HugeIcons.strokeRoundedSend,
                                  color: Colors.white,
                                  forceBackgroundColor: brandBlue,
                                  tooltip:
                                      editDraft != null ? 'Update' : 'Send',
                                  onTap: onSend,
                                ),
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

/// Icon button inside the composer capsule.
class _ComposerIconButton extends StatelessWidget {
  const _ComposerIconButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
    this.forceBackgroundColor,
    this.extraRight = 0,
  });

  final List<List<dynamic>> icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  final Color? forceBackgroundColor;
  final double extraRight;

  @override
  Widget build(BuildContext context) {
    final inline = forceBackgroundColor != null;
    // Tight gaps between composer icons, per the reference layout; the padded
    // material tap target is dropped so the 30x38 boxes keep their spacing.
    return Padding(
      padding: EdgeInsets.only(
        left: inline ? 5 : 2,
        right: (inline ? 4 : 2) + extraRight,
        top: 3,
        bottom: 3,
      ),
      child: Material(
        color: forceBackgroundColor ?? Colors.transparent,
        shape: inline ? const CircleBorder() : null,
        child: IconButton(
          icon: HugeIcon(icon: icon, size: 26, color: color),
          padding: EdgeInsets.zero,
          tooltip: tooltip,
          style: IconButton.styleFrom(
            splashFactory: NoSplash.splashFactory,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          constraints: BoxConstraints(
            minWidth: inline ? 42 : 34,
            minHeight: 46,
          ),
          onPressed: onTap,
        ),
      ),
    );
  }
}

class _ReplyBanner extends StatelessWidget {
  const _ReplyBanner({
    required this.message,
    required this.title,
    required this.onDismiss,
    required this.colorScheme,
  });

  final Message message;
  final String title;
  final VoidCallback onDismiss;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final text = message.mediaRef?.label ??
        message.decryptedText ??
        message.encryptedPayload ??
        'Message';
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Neutral surface: the themed container colors carry a pink tint from
    // the app seed color, which reads badly behind "Replying to …".
    final bannerBg = isDark ? const Color(0xFF212124) : const Color(0xFFF2F2F4);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: bannerBg,
        border: Border(
          top: BorderSide(
            color: isDark ? Colors.white12 : Colors.black12,
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 1),
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
            icon:
                const HugeIcon(icon: HugeIcons.strokeRoundedCancel01, size: 18),
            onPressed: onDismiss,
            color: colorScheme.onSurfaceVariant,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
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
          HugeIcon(
              icon: HugeIcons.strokeRoundedPencilEdit02,
              size: 16,
              color: colorScheme.tertiary),
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
            icon:
                const HugeIcon(icon: HugeIcons.strokeRoundedCancel01, size: 16),
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
              icon: const HugeIcon(icon: HugeIcons.strokeRoundedCancel01),
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
              icon: const HugeIcon(icon: HugeIcons.strokeRoundedDelete02),
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
