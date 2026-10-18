import 'package:flexiyo/core/platform_image_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:photo_manager/photo_manager.dart';

/// Gallery picker popup; resolves with the selected image bytes and whether
/// the user picked "Edit" (open the preview/crop flow) or a direct send.
Future<({Uint8List bytes, bool edit})?> showMediaGallerySheet(
  BuildContext context,
) {
  // Web has no device photo library; show upload instructions and hand the
  // chosen file to the preview/crop screen.
  if (kIsWeb) {
    return showModalBottomSheet<({Uint8List bytes, bool edit})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1B1B1D),
      barrierColor: Colors.black54,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => const _WebUploadSheet(),
    );
  }

  return showModalBottomSheet<({Uint8List bytes, bool edit})>(
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

/// Web-only picker: the browser has no photo library to browse, so explain the
/// flow and open the file chooser from a single action.
class _WebUploadSheet extends StatefulWidget {
  const _WebUploadSheet();

  @override
  State<_WebUploadSheet> createState() => _WebUploadSheetState();
}

class _WebUploadSheetState extends State<_WebUploadSheet> {
  bool _picking = false;

  Future<void> _upload() async {
    if (_picking) return;
    setState(() => _picking = true);
    final bytes = await pickImageBytes();
    if (!mounted) return;
    setState(() => _picking = false);
    if (bytes == null || bytes.isEmpty) return;
    Navigator.of(context)
        .pop<({Uint8List bytes, bool edit})>((bytes: bytes, edit: true));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const HugeIcon(
              icon: HugeIcons.strokeRoundedImageUpload,
              color: Colors.white,
              size: 40,
            ),
            const SizedBox(height: 14),
            const Text(
              'Photo library access is not available on the web.\n'
              'Pick an image from your device, then preview and crop it '
              'before sending.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white70,
                fontSize: 13.5,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: _picking ? null : _upload,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF5E5CE6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: _picking
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Upload Image',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _GalleryView { recents, albums, album }

enum _SourceAction { recents, allAlbums }

class _MediaGallerySheet extends StatefulWidget {
  const _MediaGallerySheet();

  @override
  State<_MediaGallerySheet> createState() => _MediaGallerySheetState();
}

class _MediaGallerySheetState extends State<_MediaGallerySheet> {
  final GlobalKey _titleKey = GlobalKey();

  _GalleryView _view = _GalleryView.recents;
  AssetPathEntity? _openAlbum;
  List<AssetEntity> _recentsAssets = [];
  List<AssetEntity> _assets = [];
  List<AssetPathEntity> _albums = [];
  List<AssetEntity?> _albumCovers = [];
  List<int> _albumCounts = [];
  AssetEntity? _selected;
  bool _loading = true;
  bool _albumsLoaded = false;
  bool _albumsLoading = false;
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
      // Only images are picked here: the default RequestType.common also
      // requests READ_MEDIA_VIDEO, which this app does not declare. On
      // Android 13+ that makes the whole request report denied even after
      // the user allows photos, so scope the grant to images.
      final permission = await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          androidPermission: AndroidPermission(
            type: RequestType.image,
            mediaLocation: false,
          ),
        ),
      );
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
          _recentsAssets = assets;
          _assets = assets;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String get _title {
    switch (_view) {
      case _GalleryView.recents:
        return 'Recents';
      case _GalleryView.albums:
        return 'All albums';
      case _GalleryView.album:
        return _openAlbum?.name ?? 'Album';
    }
  }

  Future<void> _loadAlbums() async {
    if (_albumsLoaded || _albumsLoading) return;
    setState(() => _albumsLoading = true);
    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: false,
      );
      final albums = <AssetPathEntity>[];
      final covers = <AssetEntity?>[];
      final counts = <int>[];
      for (final path in paths) {
        if (path.isAll) continue;
        final count = await path.assetCountAsync;
        if (count == 0) continue;
        final first = await path.getAssetListRange(start: 0, end: 1);
        albums.add(path);
        covers.add(first.isEmpty ? null : first.first);
        counts.add(count);
      }
      if (!mounted) return;
      setState(() {
        _albums = albums;
        _albumCovers = covers;
        _albumCounts = counts;
        _albumsLoaded = true;
        _albumsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _albumsLoading = false);
    }
  }

  void _showRecents() {
    setState(() {
      _view = _GalleryView.recents;
      _openAlbum = null;
      _selected = null;
      _assets = _recentsAssets;
    });
  }

  Future<void> _showAlbums() async {
    setState(() {
      _view = _GalleryView.albums;
      _openAlbum = null;
      _selected = null;
    });
    await _loadAlbums();
  }

  Future<void> _openAlbumAssets(AssetPathEntity album) async {
    setState(() {
      _view = _GalleryView.album;
      _openAlbum = album;
      _selected = null;
      _assets = [];
      _loading = true;
    });
    try {
      final assets = await album.getAssetListRange(start: 0, end: 300);
      if (mounted && _openAlbum == album) {
        setState(() {
          _assets = assets;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _goBack() {
    if (_view == _GalleryView.album) {
      setState(() {
        _view = _GalleryView.albums;
        _openAlbum = null;
        _selected = null;
      });
    } else {
      _showRecents();
    }
  }

  Future<void> _showSourcePopup() async {
    final box = _titleKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final origin = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.sizeOf(context);
    const cardWidth = 248.0;
    const cardHeight = 52.0 * 2 + 16;
    var left = origin.dx + box.size.width / 2 - cardWidth / 2;
    left = left.clamp(12.0, screen.width - cardWidth - 12);
    var top = origin.dy + box.size.height + 10;
    if (top + cardHeight > screen.height - 12) {
      top = origin.dy - cardHeight - 10;
    }

    final action = await showGeneralDialog<_SourceAction>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (dialogContext, _, __) => Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.only(left: left, top: top),
          child: _SourceMenu(
            width: cardWidth,
            recentsSelected: _view == _GalleryView.recents,
            allAlbumsSelected: _view != _GalleryView.recents,
            onSelected: (action) => Navigator.of(dialogContext).pop(action),
          ),
        ),
      ),
      transitionBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
            alignment: Alignment.topCenter,
            child: child,
          ),
        );
      },
    );

    if (action == null || !mounted) return;
    switch (action) {
      case _SourceAction.recents:
        _showRecents();
      case _SourceAction.allAlbums:
        await _showAlbums();
    }
  }

  Future<void> _confirm({required bool edit}) async {
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
        Navigator.of(context).pop((bytes: bytes, edit: edit));
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
                // Back out of albums back to Recents.
                if (_view != _GalleryView.recents)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _goBack,
                      child: const Padding(
                        padding: EdgeInsets.all(6),
                        child: HugeIcon(
                          icon: HugeIcons.strokeRoundedChevronLeft,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                // Tapping the title opens the source menu.
                GestureDetector(
                  key: _titleKey,
                  behavior: HitTestBehavior.opaque,
                  onTap: _showSourcePopup,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const HugeIcon(
                          icon: HugeIcons.strokeRoundedChevronDown,
                          color: Colors.white,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
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
          Expanded(
            child: _view == _GalleryView.albums ? _buildAlbums() : _buildGrid(),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            color: const Color(0xFF161618),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  const Spacer(),
                  GestureDetector(
                    onTap: _selected == null || _preparing
                        ? null
                        : () => _confirm(edit: true),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'Edit',
                        style: TextStyle(
                          color: _selected == null
                              ? Colors.white38
                              : Colors.white70,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: _selected == null || _preparing
                        ? null
                        : () => _confirm(edit: false),
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

  /// Albums laid out as two horizontally scrollable rows.
  Widget _buildAlbums() {
    if (_albumsLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white54),
      );
    }
    if (_albums.isEmpty) {
      return const Center(
        child: Text(
          'No albums found',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    return GridView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 14),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 14,
        childAspectRatio: 1.32,
      ),
      itemCount: _albums.length,
      itemBuilder: (context, index) {
        final album = _albums[index];
        final cover = _albumCovers[index];
        return GestureDetector(
          onTap: () => _openAlbumAssets(album),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox.expand(
                    child: cover == null
                        ? Container(color: const Color(0xFF232326))
                        : _AssetThumb(asset: cover),
                  ),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                album.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                '${_albumCounts[index]}',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        );
      },
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

/// Dropdown with the available image sources.
class _SourceMenu extends StatelessWidget {
  const _SourceMenu({
    required this.width,
    required this.recentsSelected,
    required this.allAlbumsSelected,
    required this.onSelected,
  });

  final double width;
  final bool recentsSelected;
  final bool allAlbumsSelected;
  final ValueChanged<_SourceAction> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Colors.black45,
            blurRadius: 26,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _item(
            icon: HugeIcons.strokeRoundedImage01,
            label: 'Recents',
            selected: recentsSelected,
            onTap: () => onSelected(_SourceAction.recents),
          ),
          _item(
            icon: HugeIcons.strokeRoundedGridView,
            label: 'All albums',
            selected: allAlbumsSelected,
            onTap: () => onSelected(_SourceAction.allAlbums),
          ),
        ],
      ),
    );
  }

  Widget _item({
    required List<List<dynamic>> icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: selected
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            HugeIcon(icon: icon, color: Colors.white, size: 23),
            const SizedBox(width: 16),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
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
