import 'dart:typed_data';

import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/providers/auth_provider.dart';
import 'package:flexiyo/services/media_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hugeicons/hugeicons.dart';

/// Full-screen image viewer; view-limited media consumes a client view here.
class MediaViewerScreen extends ConsumerStatefulWidget {
  const MediaViewerScreen({super.key, required this.message});

  final Message message;

  @override
  ConsumerState<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends ConsumerState<MediaViewerScreen> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _expired = false;
  String? _error;
  Offset _dragOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mediaRef = widget.message.mediaRef;
    if (mediaRef == null) {
      setState(() {
        _loading = false;
        _error = 'Unsupported media';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _expired = false;
    });
    try {
      // View-limited recipient media is never cached on disk.
      final myId = ref.read(authProvider).user?.id;
      final isMine = myId != null && widget.message.senderId == myId;
      final limited = !isMine && mediaRef.policy != ViewPolicy.unlimited;

      final bytes = await ref.read(mediaServiceProvider).fetchAndDecrypt(
            mediaRef,
            useCache: !limited,
            storeCache: !limited,
          );
      if (mounted) {
        setState(() {
          _bytes = bytes;
          _loading = false;
        });
      }
    } on MediaExpiredException {
      if (mounted) {
        setState(() {
          _expired = true;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onVerticalDragUpdate: (d) {
          setState(() => _dragOffset += Offset(0, d.delta.dy));
        },
        onVerticalDragEnd: (d) {
          if (_dragOffset.dy.abs() > 120 ||
              d.velocity.pixelsPerSecond.dy.abs() > 700) {
            Navigator.of(context).pop();
          } else {
            setState(() => _dragOffset = Offset.zero);
          }
        },
        child: Transform.translate(
          offset: _dragOffset,
          child: Stack(
            children: [
              Positioned.fill(child: _content()),
              Positioned(
                top: MediaQuery.paddingOf(context).top + 24,
                left: 12,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.35),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => Navigator.of(context).pop(),
                    child: const SizedBox(
                      width: 44,
                      height: 44,
                      child: Center(
                        child: HugeIcon(
                          icon: HugeIcons.strokeRoundedChevronLeft,
                          color: Colors.white,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.message.mediaRef?.policy == ViewPolicy.once)
                Positioned(
                  top: MediaQuery.paddingOf(context).top + 32,
                  right: 16,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Text(
                      'View once',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }
    if (_expired) {
      return _placeholder(
        icon: HugeIcons.strokeRoundedEyeOff,
        title: 'Media no longer available',
        subtitle: 'This photo reached its view limit.',
      );
    }
    if (_error != null || _bytes == null) {
      return _placeholder(
        icon: HugeIcons.strokeRoundedCloudOff,
        title: 'Could not load media',
        subtitle: 'Check your connection and try again.',
        action: TextButton(
          onPressed: _load,
          child: const Text('Retry', style: TextStyle(color: Colors.white)),
        ),
      );
    }
    return Center(
      child: InteractiveViewer(
        maxScale: 4,
        child: Image.memory(_bytes!, fit: BoxFit.contain),
      ),
    );
  }

  Widget _placeholder({
    required List<List<dynamic>> icon,
    required String title,
    required String subtitle,
    Widget? action,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          HugeIcon(icon: icon, size: 44, color: Colors.white54),
          const SizedBox(height: 14),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 13,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 10), action],
        ],
      ),
    );
  }
}
