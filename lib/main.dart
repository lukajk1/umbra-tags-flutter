import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:window_manager/window_manager.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'storage/library_store.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setTitle('Umbra Tags');
  await windowManager.setMinimumSize(const Size(1024, 600));
  await windowManager.setPreventClose(true);
  runApp(const GalleryApp());
}

Future<File> _sessionFile() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory(p.join(base.path, 'Umbra Tags'));
  await dir.create(recursive: true);
  return File(p.join(dir.path, 'flutter-session.json'));
}

Future<Map<String, dynamic>> _loadSession() async {
  try {
    final file = await _sessionFile();
    if (await file.exists()) {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    }
  } catch (_) {}
  return {};
}

Future<void> _saveSession(Map<String, dynamic> data) async {
  try {
    final file = await _sessionFile();
    await file.writeAsString(jsonEncode(data));
  } catch (_) {}
}

abstract final class AppColors {
  static const darker = Color(0xFF171717);
  static const lighter = Color(0xFF262622);
  static const accent = Color(0xFF982820);
}

enum LayoutMode { crop, letterbox, masonry }

class GalleryApp extends StatelessWidget {
  const GalleryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Umbra Tags',
      theme: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: AppColors.accent,
          onPrimary: Colors.white,
          secondary: AppColors.accent,
          onSecondary: Colors.white,
          surface: AppColors.darker,
        ),
        scaffoldBackgroundColor: AppColors.lighter,
        sliderTheme: const SliderThemeData(
          activeTrackColor: AppColors.accent,
          thumbColor: AppColors.accent,
          overlayColor: Color(0x29982820),
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return AppColors.accent;
              }
              return null;
            }),
          ),
        ),
      ),
      home: const AppShell(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AppShell extends StatelessWidget {
  const AppShell({super.key});
  @override
  Widget build(BuildContext context) => const GalleryPage();
}

class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> with WindowListener {
  double _tileSize = 200;
  LayoutMode _layout = LayoutMode.crop;
  double _committedWidth = 0;
  double _pendingWidth = 0;
  Timer? _resizeTimer;
  final Set<String> _selectedPaths = {};
  double _previewWidth = 300;
  bool _previewVisible = true;

  // Marquee selection state
  Offset? _dragStart;
  Offset? _dragCurrent;
  final _gridKey = GlobalKey();
  final _scrollController = ScrollController();

  LibraryStore? _library;
  List<LibraryAsset> _assets = [];
  List<String> _imagePaths = [];
  final Map<String, LibraryAsset> _assetsByPath = {};
  final Map<String, GlobalKey> _tileKeys = {};
  final Map<String, Future<String?>> _thumbnails = {};
  bool _busy = false;
  bool _closeRequested = false;
  bool _closingWindow = false;
  bool _showArchived = false;
  String _status = 'Create or open a library to begin';
  String? _lastLibraryPath;
  Timer? _sessionTimer;
  Future<void> _sessionWrite = Future.value();

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final data = await _loadSession();
    if (!mounted) return;
    setState(() {
      _tileSize = ((data['tileSize'] as num?)?.toDouble() ?? 200).clamp(
        50,
        400,
      );
      _previewWidth = ((data['previewWidth'] as num?)?.toDouble() ?? 300).clamp(
        150,
        800,
      );
      _lastLibraryPath = data['lastLibraryPath'] as String?;
    });
    // A sandboxed Mac must reselect the folder to grant access for this session.
    if (!Platform.isMacOS &&
        _lastLibraryPath != null &&
        !_busy &&
        _library == null) {
      await _run(() async {
        await _attach(await LibraryStore.open(_lastLibraryPath!));
      });
    }
  }

  void _persistSession() {
    _sessionTimer?.cancel();
    _sessionTimer = Timer(const Duration(milliseconds: 350), _writeSession);
  }

  void _writeSession() {
    final data = <String, dynamic>{
      'tileSize': _tileSize,
      'previewWidth': _previewWidth,
      'lastLibraryPath': _lastLibraryPath,
    };
    _sessionWrite = _sessionWrite.then((_) => _saveSession(data));
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy || _closingWindow) return;
    setState(() => _busy = true);
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Library operation could not finish'),
            content: SelectableText(error.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      if (_closeRequested && mounted) onWindowClose();
    }
  }

  Future<void> _attach(LibraryStore library) async {
    if (!mounted) {
      await library.close();
      return;
    }
    await _library?.close();
    _library = library;
    _lastLibraryPath = library.root;
    _showArchived = false;
    _thumbnails.clear();
    await _reload();
    _persistSession();
  }

  Future<void> _reload() async {
    final assets = await _library!.assets(archived: _showArchived);
    if (!mounted) return;
    setState(() {
      _assets = assets;
      _imagePaths = assets
          .map((a) => _library!.absolutePath(a.relativePath))
          .toList();
      _assetsByPath.clear();
      for (var i = 0; i < assets.length; i++) {
        _assetsByPath[_imagePaths[i]] = assets[i];
      }
      _tileKeys.removeWhere((key, _) => !_assetsByPath.containsKey(key));
      for (final path in _imagePaths) {
        _tileKeys.putIfAbsent(path, () => GlobalKey());
      }
      _selectedPaths.removeWhere((path) => !_assetsByPath.containsKey(path));
      _status =
          '${assets.length} images${_showArchived ? ' archived' : ''}'
          '${assets.any((a) => a.missing) ? ' · ${assets.where((a) => a.missing).length} missing' : ''}';
    });
  }

  Future<String?> _thumbnailFor(String path) {
    if (_thumbnails.length > 256) _thumbnails.remove(_thumbnails.keys.first);
    return _thumbnails.putIfAbsent(
      path,
      () => _library!.thumbnail(_assetsByPath[path]!),
    );
  }

  void _createLibrary() => _run(() async {
    final folder = await getDirectoryPath(
      confirmButtonText: 'Use empty folder',
    );
    if (folder == null || !mounted) return;
    final input = TextEditingController(text: p.basename(folder));
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New library'),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Library name'),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (input.text.trim().isNotEmpty) {
                Navigator.pop(context, input.text);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    // Wait until the closing dialog has detached its editable text.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    input.dispose();
    if (name != null) await _attach(await LibraryStore.create(folder, name));
  });

  void _openLibrary() => _run(() async {
    final folder = await getDirectoryPath(
      initialDirectory: _lastLibraryPath,
      confirmButtonText: 'Open library',
    );
    if (folder != null) await _attach(await LibraryStore.open(folder));
  });

  void _closeLibrary() => _run(() async {
    await _library?.close();
    if (!mounted) return;
    setState(() {
      _library = null;
      _assets = [];
      _imagePaths = [];
      _assetsByPath.clear();
      _tileKeys.clear();
      _selectedPaths.clear();
      _thumbnails.clear();
      _status = 'Library closed';
    });
  });

  void _importImages() => _run(() async {
    final library = _library;
    if (library == null) return;
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: LibraryStore.supportedExtensions,
          uniformTypeIdentifiers: ['public.image'],
        ),
      ],
    );
    var added = 0;
    var duplicates = 0;
    final errors = <String>[];
    for (var i = 0; i < files.length; i++) {
      if (mounted) {
        setState(() => _status = 'Importing ${i + 1} of ${files.length}…');
      }
      try {
        final result = await library.importImage(files[i].path);
        if (result.duplicate) {
          duplicates++;
        } else {
          added++;
        }
      } catch (error) {
        errors.add('${files[i].name}: $error');
      }
    }
    if (files.isEmpty) return;
    _thumbnails.clear();
    await _reload();
    if (mounted) {
      setState(
        () => _status =
            '$added imported · $duplicates already in library'
            '${errors.isNotEmpty ? ' · ${errors.length} failed' : ''}',
      );
    }
    if (errors.isNotEmpty) throw LibraryException(errors.join('\n'));
  });

  void _archiveSelection() => _run(() async {
    await _library!.archive(
      _selectedPaths.map((path) => _assetsByPath[path]!.id).toList(),
      !_showArchived,
    );
    await _reload();
  });

  void _refreshLibrary() => _run(() async {
    await _library!.refresh();
    _thumbnails.clear();
    await _reload();
  });

  void _backupLibrary() => _run(() async {
    final backup = await _library!.backup();
    if (mounted) {
      setState(() => _status = 'Metadata backup saved: ${p.basename(backup)}');
    }
  });

  @override
  void onWindowClose() async {
    _closeRequested = true;
    if (_busy || _closingWindow) return;
    _closingWindow = true;
    _sessionTimer?.cancel();
    _writeSession();
    await _sessionWrite;
    await _library?.close();
    await windowManager.destroy();
  }

  void _onLayoutWidth(double width) {
    if (width == _committedWidth) return;
    _pendingWidth = width;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _committedWidth = _pendingWidth);
    });
  }

  @override
  void dispose() {
    _resizeTimer?.cancel();
    _sessionTimer?.cancel();
    windowManager.removeListener(this);
    unawaited(_library?.close() ?? Future<void>.value());
    _scrollController.dispose();
    super.dispose();
  }

  int _columnCount(double availableWidth) =>
      (availableWidth / _tileSize).floor().clamp(1, 999);

  Rect? get _selectionRect {
    if (_dragStart == null || _dragCurrent == null) return null;
    return Rect.fromPoints(_dragStart!, _dragCurrent!);
  }

  void _updateMarqueeSelection() {
    final rect = _selectionRect;
    if (rect == null) return;
    final gridBox = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (gridBox == null) return;

    final selected = <String>{};
    for (final path in _imagePaths) {
      final tileBox =
          _tileKeys[path]?.currentContext?.findRenderObject() as RenderBox?;
      if (tileBox == null) continue;
      // Convert tile position to grid-local coordinates
      final tileOffset = tileBox.localToGlobal(Offset.zero, ancestor: gridBox);
      final tileRect = tileOffset & tileBox.size;
      if (rect.overlaps(tileRect)) selected.add(path);
    }
    setState(
      () => _selectedPaths
        ..clear()
        ..addAll(selected),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: MenuBar(
          style: const MenuStyle(
            backgroundColor: WidgetStatePropertyAll(Colors.transparent),
            elevation: WidgetStatePropertyAll(0),
            padding: WidgetStatePropertyAll(EdgeInsets.zero),
          ),
          children: [
            SubmenuButton(
              menuChildren: [
                MenuItemButton(
                  onPressed: _busy ? null : _createLibrary,
                  child: const Text('New library…'),
                ),
                MenuItemButton(
                  onPressed: _busy ? null : _openLibrary,
                  child: const Text('Open library…'),
                ),
                MenuItemButton(
                  onPressed: _busy || _library == null ? null : _importImages,
                  child: const Text('Import images…'),
                ),
                MenuItemButton(
                  onPressed: _busy || _library == null ? null : _backupLibrary,
                  child: const Text('Back up metadata'),
                ),
                MenuItemButton(
                  onPressed: _busy || _library == null ? null : _closeLibrary,
                  child: const Text('Close library'),
                ),
                const Divider(),
                MenuItemButton(
                  onPressed: _busy ? null : () => windowManager.close(),
                  child: const Text('Quit'),
                ),
              ],
              child: const Text('File'),
            ),
            SubmenuButton(
              menuChildren: [
                MenuItemButton(
                  onPressed: _imagePaths.isEmpty
                      ? null
                      : () =>
                            setState(() => _selectedPaths.addAll(_imagePaths)),
                  child: const Text('Select all'),
                ),
                MenuItemButton(
                  onPressed: _busy || _selectedPaths.isEmpty
                      ? null
                      : _archiveSelection,
                  child: Text(
                    _showArchived ? 'Restore selected' : 'Archive selected',
                  ),
                ),
              ],
              child: const Text('Edit'),
            ),
            SubmenuButton(
              menuChildren: [
                MenuItemButton(
                  onPressed: () {
                    setState(() => _tileSize = (_tileSize + 25).clamp(50, 400));
                    _persistSession();
                  },
                  child: const Text('Zoom in'),
                ),
                MenuItemButton(
                  onPressed: _busy || _library == null
                      ? null
                      : () => _run(() async {
                          _showArchived = !_showArchived;
                          await _reload();
                        }),
                  child: Text(_showArchived ? 'Show library' : 'Show archive'),
                ),
                MenuItemButton(
                  onPressed: _busy || _library == null ? null : _refreshLibrary,
                  child: const Text('Refresh files'),
                ),
                MenuItemButton(
                  onPressed: () {
                    setState(() => _tileSize = (_tileSize - 25).clamp(50, 400));
                    _persistSession();
                  },
                  child: const Text('Zoom out'),
                ),
              ],
              child: const Text('View'),
            ),
            SubmenuButton(
              menuChildren: [
                MenuItemButton(
                  onPressed: () => showAboutDialog(
                    context: context,
                    applicationName: 'Umbra Tags',
                    applicationVersion: 'Library format 1',
                  ),
                  child: const Text('About'),
                ),
              ],
              child: const Text('Help'),
            ),
          ],
        ),
        titleSpacing: 0,
        actions: [
          SegmentedButton<LayoutMode>(
            segments: const [
              ButtonSegment(
                value: LayoutMode.crop,
                icon: Icon(Icons.grid_view_rounded, semanticLabel: 'Crop'),
                tooltip: 'Crop — fill uniform tiles',
              ),
              ButtonSegment(
                value: LayoutMode.letterbox,
                icon: Icon(Icons.fit_screen_rounded, semanticLabel: 'Fit'),
                tooltip: 'Fit — show the whole image',
              ),
              ButtonSegment(
                value: LayoutMode.masonry,
                icon: Icon(Icons.view_quilt_rounded, semanticLabel: 'Masonry'),
                tooltip: 'Masonry — arrange by image proportions',
              ),
            ],
            showSelectedIcon: false,
            selected: {_layout},
            onSelectionChanged: (s) => setState(() => _layout = s.first),
          ),
          const SizedBox(width: 16),
          const Icon(Icons.photo_size_select_large),
          SizedBox(
            width: 180,
            child: Slider(
              value: _tileSize,
              min: 50,
              max: 400,
              label: '${_tileSize.round()}px',
              onChanged: (v) {
                setState(() => _tileSize = v);
                _persistSession();
              },
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              _previewVisible
                  ? Icons.view_sidebar
                  : Icons.view_sidebar_outlined,
            ),
            tooltip: _previewVisible ? 'Hide preview' : 'Show preview',
            onPressed: () => setState(() => _previewVisible = !_previewVisible),
          ),
          const SizedBox(width: 4),
        ],
      ),
      bottomNavigationBar: Container(
        color: AppColors.darker,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            if (_busy) ...[
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _library?.name ?? 'Umbra Tags',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    _status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (_selectedPaths.isNotEmpty)
              Text('${_selectedPaths.length} selected  '),
            if (_library != null)
              FilledButton.icon(
                onPressed: _busy ? null : _importImages,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Import images'),
              ),
          ],
        ),
      ),
      body: _library == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.photo_library_outlined,
                    size: 48,
                    color: Colors.white38,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Your images. Your library.',
                    style: TextStyle(fontSize: 24),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Keep each library in a folder you choose.',
                    style: TextStyle(color: Colors.white60),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 12,
                    children: [
                      FilledButton(
                        onPressed: _busy ? null : _createLibrary,
                        child: const Text('New library'),
                      ),
                      OutlinedButton(
                        onPressed: _busy ? null : _openLibrary,
                        child: const Text('Open library'),
                      ),
                    ],
                  ),
                ],
              ),
            )
          : Row(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _onLayoutWidth(constraints.maxWidth);
                      final width = _committedWidth > 0
                          ? _committedWidth
                          : constraints.maxWidth;
                      final cols = _columnCount(width);

                      if (_assets.isEmpty) {
                        return Center(
                          child: Text(
                            _showArchived
                                ? 'No archived images'
                                : 'Import images to fill this library',
                            style: const TextStyle(color: Colors.white54),
                          ),
                        );
                      }
                      Widget grid;
                      if (_layout == LayoutMode.masonry) {
                        grid = MasonryGridView.builder(
                          key: _gridKey,
                          controller: _scrollController,
                          gridDelegate:
                              SliverSimpleGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: cols,
                              ),
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          itemCount: _imagePaths.length,
                          itemBuilder: (context, index) => GalleryTile(
                            key: _tileKeys[_imagePaths[index]],
                            path: _imagePaths[index],
                            thumbnail: _thumbnailFor(_imagePaths[index]),
                            aspectRatio:
                                _assets[index].width / _assets[index].height,
                            filename: _assets[index].originalFilename,
                            tileSize: _tileSize,
                            layout: _layout,
                            selected: _selectedPaths.contains(
                              _imagePaths[index],
                            ),
                            onTap: () => setState(() {
                              _selectedPaths.clear();
                              _selectedPaths.add(_imagePaths[index]);
                            }),
                          ),
                        );
                      } else {
                        grid = GridView.builder(
                          key: _gridKey,
                          controller: _scrollController,
                          itemCount: _imagePaths.length,
                          gridDelegate:
                              SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: _tileSize,
                                mainAxisSpacing: 8,
                                crossAxisSpacing: 8,
                              ),
                          itemBuilder: (context, index) => GalleryTile(
                            key: _tileKeys[_imagePaths[index]],
                            path: _imagePaths[index],
                            thumbnail: _thumbnailFor(_imagePaths[index]),
                            aspectRatio:
                                _assets[index].width / _assets[index].height,
                            filename: _assets[index].originalFilename,
                            tileSize: _tileSize,
                            layout: _layout,
                            selected: _selectedPaths.contains(
                              _imagePaths[index],
                            ),
                            onTap: () => setState(() {
                              _selectedPaths.clear();
                              _selectedPaths.add(_imagePaths[index]);
                            }),
                          ),
                        );
                      }

                      return Listener(
                        onPointerDown: (e) {
                          // Only start marquee on left button drag, not scroll wheel
                          if (e.buttons == 1) {
                            setState(() {
                              _dragStart = e.localPosition;
                              _dragCurrent = e.localPosition;
                            });
                          }
                        },
                        onPointerMove: (e) {
                          if (_dragStart != null) {
                            setState(() => _dragCurrent = e.localPosition);
                            _updateMarqueeSelection();
                          }
                        },
                        onPointerUp: (_) => setState(() {
                          _dragStart = null;
                          _dragCurrent = null;
                        }),
                        child: ScrollConfiguration(
                          behavior: _GalleryScrollBehavior(),
                          child: Scrollbar(
                            controller: _scrollController,
                            thickness: 8,
                            radius: const Radius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: Stack(
                                children: [
                                  grid,
                                  if (_selectionRect != null)
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: CustomPaint(
                                          painter: _MarqueePainter(
                                            _selectionRect!,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (_previewVisible) ...[
                  // Drag handle
                  GestureDetector(
                    onHorizontalDragUpdate: (d) => setState(() {
                      _previewWidth = (_previewWidth - d.delta.dx).clamp(
                        150,
                        800,
                      );
                      _persistSession();
                    }),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeColumn,
                      child: Container(width: 6, color: Colors.white12),
                    ),
                  ),
                  // Preview pane
                  SizedBox(
                    width: _previewWidth,
                    child: DecoratedBox(
                      decoration: const BoxDecoration(color: AppColors.darker),
                      child: SizedBox.expand(
                        child: _selectedPaths.isNotEmpty
                            ? Image.file(
                                File(_selectedPaths.first),
                                fit: BoxFit.contain,
                                cacheWidth:
                                    (_previewWidth *
                                            MediaQuery.devicePixelRatioOf(
                                              context,
                                            ))
                                        .ceil(),
                                errorBuilder: (_, _, _) => const Center(
                                  child: Text(
                                    'Original file is missing or unreadable',
                                  ),
                                ),
                              )
                            : const Center(
                                child: Text(
                                  'No image selected',
                                  style: TextStyle(color: Colors.white24),
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class GalleryTile extends StatelessWidget {
  const GalleryTile({
    super.key,
    required this.path,
    required this.thumbnail,
    required this.aspectRatio,
    required this.filename,
    required this.tileSize,
    required this.layout,
    required this.selected,
    required this.onTap,
  });

  final String path;
  final Future<String?> thumbnail;
  final double aspectRatio;
  final String filename;
  final double tileSize;
  final LayoutMode layout;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final image = FutureBuilder<String?>(
      future: thumbnail,
      builder: (context, snapshot) {
        final placeholder = ColoredBox(
          color: Colors.white10,
          child: Center(
            child: Icon(
              snapshot.connectionState == ConnectionState.waiting
                  ? Icons.image_outlined
                  : Icons.broken_image_outlined,
              color: Colors.white24,
            ),
          ),
        );
        if (snapshot.data == null) return placeholder;
        return LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.devicePixelRatioOf(context);
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            final decodeByHeight =
                layout == LayoutMode.crop &&
                height.isFinite &&
                aspectRatio > width / height;
            return Image.file(
              File(snapshot.data!),
              fit: layout == LayoutMode.crop ? BoxFit.cover : BoxFit.contain,
              cacheWidth: decodeByHeight
                  ? null
                  : (width * scale).ceil().clamp(1, 1280),
              cacheHeight: decodeByHeight
                  ? (height * scale).ceil().clamp(1, 1280)
                  : null,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => placeholder,
            );
          },
        );
      },
    );
    return GestureDetector(
      onTap: onTap,
      onSecondaryTapUp: (d) => _showContextMenu(context, d.globalPosition),
      child: Stack(
        fit: layout == LayoutMode.masonry ? StackFit.loose : StackFit.expand,
        children: [
          layout == LayoutMode.masonry
              ? AspectRatio(aspectRatio: aspectRatio, child: image)
              : ColoredBox(color: AppColors.lighter, child: image),
          if (selected)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.accent, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: const [
        PopupMenuItem(value: 'copy', child: Text('Copy file path')),
        PopupMenuItem(value: 'info', child: Text('Image info')),
      ],
    );
    if (choice == 'copy') await Clipboard.setData(ClipboardData(text: path));
    if (choice == 'info' && context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(filename),
          content: SelectableText(path),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    }
  }
}

class _MarqueePainter extends CustomPainter {
  _MarqueePainter(this.rect);
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      rect,
      Paint()
        ..color = AppColors.accent.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = AppColors.accent.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_MarqueePainter old) => old.rect != rect;
}

class _GalleryScrollBehavior extends ScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.trackpad,
  };

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child; // suppress built-in scrollbar — we render our own
}
