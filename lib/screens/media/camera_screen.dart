import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flexiyo/providers/conversation_provider.dart';
import 'package:flexiyo/services/media_service.dart';
import 'package:flexiyo/widgets/avatar.dart';
import 'package:flexiyo/widgets/media_gallery_sheet.dart';
import 'package:flexiyo/widgets/media_image_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hugeicons/hugeicons.dart';

/// Camera capture + review flow; pass [initialImage] to open directly in
/// review (used by the gallery picker so library photos get the same
/// view-policy step).
class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({
    super.key,
    required this.conversationId,
    this.initialImage,
    this.otherUsername,
  });

  final String conversationId;
  final Uint8List? initialImage;
  final String? otherUsername;

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  bool _initializing = true;
  bool _capturing = false;
  String? _initError;
  FlashMode _flashMode = FlashMode.auto;

  Uint8List? _captured;
  ViewPolicy _policy = ViewPolicy.twice;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialImage != null) {
      _captured = widget.initialImage;
      _initializing = false;
    } else {
      _initCamera();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    try {
      // The camera plugin prompts for permission during initialize().
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _initError = 'No camera available';
            _initializing = false;
          });
        }
        return;
      }
      await _bindCamera(_cameraIndex);
    } on CameraException catch (e) {
      if (mounted) {
        setState(() {
          _initError = _isPermissionError(e)
              ? 'Camera access is off'
              : 'Camera unavailable';
          _initializing = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _initError = 'Camera unavailable';
          _initializing = false;
        });
      }
    }
  }

  bool _isPermissionError(CameraException e) => const {
        'CameraAccessDenied',
        'CameraAccessDeniedWithoutPrompt',
        'CameraAccessRestricted',
        'cameraPermission',
      }.contains(e.code);

  Future<void> _bindCamera(int index) async {
    await _controller?.dispose();
    final controller = CameraController(
      _cameras[index],
      ResolutionPreset.high,
      enableAudio: false,
    );
    await controller.initialize();
    try {
      await controller.setFlashMode(_flashMode);
    } catch (_) {
      // Front cameras and some hardware do not expose flash modes.
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _cameraIndex = index;
      _initializing = false;
    });
  }

  Future<void> _flip() async {
    if (_cameras.length < 2) return;
    final next = (_cameraIndex + 1) % _cameras.length;
    setState(() => _initializing = true);
    try {
      await _bindCamera(next);
    } catch (_) {
      setState(() => _initializing = false);
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) {
      return;
    }
    setState(() => _capturing = true);
    try {
      final shot = await controller.takePicture();
      final bytes = await shot.readAsBytes();
      unawaited(() async {
        try {
          await File(shot.path).delete();
        } catch (_) {}
      }());
      if (mounted) {
        setState(() {
          _captured = bytes;
          _capturing = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _pickFromGallery() async {
    final bytes = await showMediaGallerySheet(context);
    if (bytes != null && mounted) {
      setState(() => _captured = bytes);
    }
  }

  bool get _hasFlash {
    final controller = _controller;
    if (controller == null || _cameras.isEmpty) return false;
    return _cameras[_cameraIndex].lensDirection == CameraLensDirection.back;
  }

    List<List<dynamic>> get _flashIcon => switch (_flashMode) {
      FlashMode.off => HugeIcons.strokeRoundedFlashOff,
      FlashMode.auto => HugeIcons.strokeRoundedFlash,
      _ => HugeIcons.strokeRoundedFlash,
      };

  Future<void> _cycleFlash() async {
    final next = switch (_flashMode) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.always,
      _ => FlashMode.off,
    };
    setState(() => _flashMode = next);
    try {
      await _controller?.setFlashMode(next);
    } catch (_) {}
  }

  void _showEffectsNotice() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Effects are coming soon'),
        duration: Duration(milliseconds: 900),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _handleBack() async {
    if (_captured == null) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await _showDiscardDialog();
    if (discard && mounted) {
      setState(() => _captured = null);
      Navigator.of(context).pop();
    }
  }

  Future<bool> _showDiscardDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF2A2C31),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 22, 24, 18),
              child: Column(
                children: [
                  Text(
                    'Discard photo?',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'If you go back now, you will lose your photo.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
            ),
            Container(height: 0.5, color: Colors.white12),
            InkWell(
              onTap: () => Navigator.of(ctx).pop(true),
              child: const SizedBox(
                width: double.infinity,
                height: 50,
                child: Center(
                  child: Text(
                    'Discard',
                    style: TextStyle(
                      color: Color(0xFFFF2E63),
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            Container(height: 0.5, color: Colors.white12),
            InkWell(
              onTap: () => Navigator.of(ctx).pop(false),
              child: const SizedBox(
                width: double.infinity,
                height: 50,
                child: Center(
                  child: Text(
                    'Keep editing',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }

  Future<void> _showPolicyPopup() async {
    final picked = await showDialog<ViewPolicy>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF2A2D34),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.only(left: 28, right: 90, bottom: 130),
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 14, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(right: 20),
                child: Text(
                  'Set how many times this photo can be viewed.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              for (final option in ViewPolicy.values)
                _PolicyOption(
                  policy: option,
                  selected: _policy == option,
                  onTap: () => Navigator.of(ctx).pop(option),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() => _policy = picked);
    }
  }

  Future<void> _send() async {
    final bytes = _captured;
    if (bytes == null || _sending) return;
    setState(() => _sending = true);
    try {
      final service = ref.read(mediaServiceProvider);
      final mediaRef = await service.encryptAndUpload(
        bytes: bytes,
        conversationId: widget.conversationId,
        kind: MediaKind.image,
        policy: _policy,
      );
      await ref
          .read(conversationProvider(widget.conversationId).notifier)
          .sendMessage(mediaRef.toEnvelopeString());
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send photo: $e')),
        );
      }
    }
  }

  String get _otherUsername {
    return widget.otherUsername ??
        ref
            .read(conversationProvider(widget.conversationId))
            .conversation
            ?.otherUsername ??
        '';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _captured != null ? _buildReview() : _buildCapture(),
      ),
    );
  }

  Widget _buildCapture() {
    final controller = _controller;
    final previewReady =
        controller != null && controller.value.isInitialized && !_initializing;

    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const HugeIcon(
                    icon: HugeIcons.strokeRoundedCancel01,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      _otherUsername.isEmpty
                          ? 'Camera'
                          : 'Message $_otherUsername',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (_hasFlash)
                  IconButton(
                    onPressed: _cycleFlash,
                    tooltip: 'Flash',
                    icon: HugeIcon(
                      icon: _flashIcon,
                      color: Colors.white,
                      size: 24,
                    ),
                  )
                else
                  const SizedBox(width: 48),
              ],
            ),
          ),
        ),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (previewReady)
                CameraPreview(controller)
              else if (_initializing)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white54),
                )
              else
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const HugeIcon(
                        icon: HugeIcons.strokeRoundedCameraOff01,
                        color: Colors.white38,
                        size: 42,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _initError ?? 'Camera unavailable',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 13.5),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: _EffectsChip(onTap: _showEffectsNotice),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _BottomSquareButton(
                      onTap: _pickFromGallery,
                      child: const HugeIcon(
                        icon: HugeIcons.strokeRoundedImages,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _capture,
                      child: Container(
                        width: 78,
                        height: 78,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 4),
                        ),
                        padding: const EdgeInsets.all(6),
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                          child: _capturing
                              ? const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    color: Colors.black87,
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                    const Spacer(),
                    _BottomSquareButton(
                      onTap: _cameras.length > 1 ? _flip : null,
                      child: HugeIcon(
                        icon: HugeIcons.strokeRoundedCameraRotated01,
                        color:
                            _cameras.length > 1 ? Colors.white : Colors.white30,
                        size: 28,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReview() {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            color: Colors.black,
            alignment: Alignment.center,
            child: Image.memory(_captured!, fit: BoxFit.contain),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: IconButton(
              onPressed: _handleBack,
              icon: const HugeIcon(
                icon: HugeIcons.strokeRoundedChevronLeft,
                color: Colors.white,
                size: 26,
              ),
            ),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  ViewPolicyChip(
                    policy: _policy,
                    dark: true,
                    onTap: _showPolicyPopup,
                  ),
                  const Spacer(),
                  _SendPill(
                    username: _otherUsername,
                    sending: _sending,
                    onTap: _send,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _BottomSquareButton extends StatelessWidget {
  const _BottomSquareButton({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white12,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox(width: 48, height: 48, child: Center(child: child)),
      ),
    );
  }
}

class _EffectsChip extends StatelessWidget {
  const _EffectsChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HugeIcon(
              icon: HugeIcons.strokeRoundedSparkles,
              color: Colors.white,
              size: 15,
            ),
            SizedBox(width: 6),
            Text(
              'Effects',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SendPill extends StatelessWidget {
  const _SendPill({
    required this.username,
    required this.sending,
    required this.onTap,
  });

  final String username;
  final bool sending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(26),
      child: InkWell(
        borderRadius: BorderRadius.circular(26),
        onTap: sending ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              UserAvatar(username: username, radius: 15),
              const SizedBox(width: 9),
              if (sending)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Colors.black87,
                  ),
                )
              else
                const Text(
                  'Send',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PolicyOption extends StatelessWidget {
  const _PolicyOption({
    required this.policy,
    required this.selected,
    required this.onTap,
  });

  final ViewPolicy policy;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            ViewPolicyGlyph(policy: policy, size: 26),
            const SizedBox(width: 13),
            Expanded(
              child: Text(
                policy.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (selected)
              const HugeIcon(
                icon: HugeIcons.strokeRoundedCheck,
                color: Colors.white,
                size: 18,
              ),
          ],
        ),
      ),
    );
  }
}
