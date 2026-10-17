import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:photo_manager/photo_manager.dart';

/// Gallery picker popup; resolves with the selected image bytes.
Future<Uint8List?> showMediaGallerySheet(BuildContext context) {
  return showModalBottomSheet<Uint8List>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1B1B1D),
    barrierColor: Colors.black54,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => const _MediaGallerySheet(),
  );
}

class _MediaGallerySheet extends StatefulWidget {
  const _MediaGallerySheet();

  @override
  State<_MediaGallerySheet> createState() => _MediaGallerySheetState();
}

class _MediaGallerySheetState extends State<_MediaGallerySheet> {
  List<AssetEntity> _assets = [];
  AssetEntity? _selected;
  bool _loading = true;
  bool _denied = false;
  bool _hd = true;
  bool _preparing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.hasAccess) {
        setState(() {
          _denied = true;
          _loading = false;
        });
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
        filterOption: FilterOptionGroup(
          orders: [
            const OrderOption(type: OrderOptionType.createDate, asc: false),
          ],
        ),
      );
      if (albums.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      final assets = await albums.first.getAssetListRange(start: 0, end: 150);
      if (mounted) {
        setState(() {
          _assets = assets;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirm() async {
    final asset = _selected;
    if (asset == null || _preparing) return;
    setState(() => _preparing = true);
    try {
      Uint8List? bytes = await asset.originBytes;
      if (bytes == null) {
        final file = await asset.file;
        bytes = await file?.readAsBytes();
      }
      if (bytes != null && mounted) {
        Navigator.of(context).pop(bytes);
        return;
      }
    } catch (_) {}
    if (mounted) setState(() => _preparing = false);
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.5;

    return SizedBox(
      height: height,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Recents',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(width: 4),
                    HugeIcon(
                      icon: HugeIcons.strokeRoundedChevronDown,
                      color: Colors.white,
                      size: 20,
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: GestureDetector(
                    onTap: () => setState(() => _hd = !_hd),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: _hd ? Colors.white : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: _hd ? Colors.white : Colors.white54,
                          width: 1.4,
                        ),
                      ),
                      child: Text(
                        'HD',
                        style: TextStyle(
                          color: _hd ? Colors.black : Colors.white54,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(child: _buildGrid()),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            color: const Color(0xFF161618),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Edit',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: _selected == null ? null : _confirm,
                    child: Container(
                      width: 74,
                      height: 42,
                      decoration: BoxDecoration(
                        color:
                            _selected == null ? Colors.white38 : Colors.white,
                        borderRadius: BorderRadius.circular(21),
                      ),
                      child: Center(
                        child: _preparing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.black,
                                ),
                              )
                            : const HugeIcon(
                                icon: HugeIcons.strokeRoundedSend,
                                color: Colors.black,
                                size: 20,
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    if (_denied) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Photo access is required to pick images.\nEnable it in Settings.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13.5),
              ),
              const SizedBox(height: 12),
              // Re-checks access as soon as the user is back from Settings.
              TextButton(
                onPressed: () async {
                  await PhotoManager.openSetting();
                  if (!mounted) return;
                  setState(() {
                    _denied = false;
                    _loading = true;
                  });
                  _load();
                },
                child: const Text('Open settings'),
              ),
            ],
          ),
        ),
      );
    }
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white54),
      );
    }
    if (_assets.isEmpty) {
      return const Center(
        child: Text(
          'No photos found',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    return GridView.builder(
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        childAspectRatio: 1,
      ),
      itemCount: _assets.length,
      itemBuilder: (context, index) {
        final asset = _assets[index];
        final isSelected = identical(asset, _selected);
        return GestureDetector(
          onTap: () => setState(
            () => _selected = isSelected ? null : asset,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _AssetThumb(asset: asset),
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        isSelected ? const Color(0xFF2D6BFF) : Colors.black26,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.9),
                      width: 1.6,
                    ),
                  ),
                  child: isSelected
                      ? const HugeIcon(
                          icon: HugeIcons.strokeRoundedCheck,
                          size: 13,
                          color: Colors.white,
                        )
                      : null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AssetThumb extends StatelessWidget {
  const _AssetThumb({required this.asset});

  final AssetEntity asset;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: asset.thumbnailDataWithSize(
        const ThumbnailSize.square(300),
        quality: 82,
      ),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) {
          return Container(color: const Color(0xFF232326));
        }
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        );
      },
    );
  }
}
