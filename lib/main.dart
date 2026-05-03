import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setMinimumSize(const Size(1024, 600));
  runApp(const GalleryApp());
}

const List<String> kImagePaths = [
  'assets/1fb67eb6388cf8bca406b56db24853c2.jpg',
  'assets/226a8e612c89158946e63f8649fd0a7c.jpg',
  'assets/2bd2680d14c15161c8b9ce1ba1bfa925.jpg',
  'assets/36ac1865b363df87d21758707da03ecf.jpg',
  'assets/3791968cb708849b64d65ffde24e9956.jpg',
  'assets/46de5289260bc4b294290366f4d528f2.jpg',
  'assets/4c5a2313b89628fb5ae49b11a6aa0b01.jpg',
  'assets/55549e1e1aee31d0d6ebccaa1fe6feac.jpg',
  'assets/56abbe593c2b02df18b4503873c38dce.jpg',
  'assets/5b57ac246a7a231fe084a343fe6948c0.jpg',
  'assets/6e0cc4ab142b1939cef62d42d8fb373d.jpg',
  'assets/722925b430e4229f508a39e047b27ced.jpg',
  'assets/7413f8ababa6c8a189300a839aa12096.jpg',
  'assets/808c4019dc6e043bc7614b1e6054da97.jpg',
  'assets/84e378dbdf4f0e2cd8bfd1082b849249.jpg',
  'assets/91046e2b718f0bf8a893028e176c93b4.jpg',
  'assets/94355400b0d5ea441bf75f31fe2043ad.jpg',
  'assets/a268fb5f2ba66860608a2f96bedec209.jpg',
  'assets/ac50ce52f36abd8321542d1c8edd2363.jpg',
  'assets/b49ae47b68ed40731ce11104b25cbfe1.jpg',
  'assets/b66125e523a8cefdb070ad71aabd8e24.jpg',
  'assets/b83da54e38c0373ddf6ce2903c6056ad.png',
  'assets/bc4afa81cf01d6c36813c0a55af1b2ab.jpg',
  'assets/bf638f8b2916fba83b2fab2e0ebf0299.jpg',
  'assets/c1277fbc6a74140a88c585415c30f16d.jpg',
  'assets/c4032a9405c5065216cd8d1f7bae984d.jpg',
  'assets/ced1de476bb88d580539ebee904b4830.jpg',
  'assets/d04bb4a96e610cbb4f757a0b50cd7c13.jpg',
  'assets/d5f614d10dc8fc8fd79441d3bb928454.jpg',
  'assets/de2598edf849f4e0d9656775b04adee1.jpg',
  'assets/e20d8402850e0787c70d90e13e75430c.jpg',
  'assets/e64164b41548a89d3a0c2e0c7551a2a4.jpg',
  'assets/f3dd5775d2893552774d99b8da6c0c0a.jpg',
  'assets/f592e90c35a422a4416736a28a3d5cd3.jpg',
];

enum LayoutMode { crop, letterbox, masonry }

class GalleryApp extends StatelessWidget {
  const GalleryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Image Gallery',
      theme: ThemeData.dark(),
      home: const AppShell(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformMenuBar(
      menus: [
        PlatformMenu(label: 'File', menus: [
          PlatformMenuItem(
            label: 'Open...',
            shortcut: const SingleActivator(LogicalKeyboardKey.keyO, meta: true),
            onSelected: () {},
          ),
          PlatformMenuItem(label: 'Close', onSelected: () {}),
          const PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: 'Quit', onSelected: null),
          ]),
        ]),
        PlatformMenu(label: 'Edit', menus: [
          PlatformMenuItem(label: 'Select All', onSelected: () {}),
        ]),
        PlatformMenu(label: 'View', menus: [
          PlatformMenuItem(label: 'Zoom In', onSelected: () {}),
          PlatformMenuItem(label: 'Zoom Out', onSelected: () {}),
        ]),
        PlatformMenu(label: 'Help', menus: [
          PlatformMenuItem(label: 'About', onSelected: () {}),
        ]),
      ],
      child: const GalleryPage(),
    );
  }
}

class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
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
  final Map<String, GlobalKey> _tileKeys = {
    for (final p in kImagePaths) p: GlobalKey(),
  };

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
    for (final path in kImagePaths) {
      final tileBox = _tileKeys[path]?.currentContext?.findRenderObject() as RenderBox?;
      if (tileBox == null) continue;
      // Convert tile position to grid-local coordinates
      final tileOffset = tileBox.localToGlobal(Offset.zero, ancestor: gridBox);
      final tileRect = tileOffset & tileBox.size;
      if (rect.overlaps(tileRect)) selected.add(path);
    }
    setState(() => _selectedPaths
      ..clear()
      ..addAll(selected));
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
                MenuItemButton(child: const Text('Open...'), onPressed: () {}),
                MenuItemButton(child: const Text('Close'), onPressed: () {}),
                const Divider(),
                MenuItemButton(child: const Text('Quit'), onPressed: () {}),
              ],
              child: const Text('File'),
            ),
            SubmenuButton(
              menuChildren: [
                MenuItemButton(child: const Text('Select All'), onPressed: () {}),
              ],
              child: const Text('Edit'),
            ),
            SubmenuButton(
              menuChildren: [
                MenuItemButton(child: const Text('Zoom In'), onPressed: () {}),
                MenuItemButton(child: const Text('Zoom Out'), onPressed: () {}),
              ],
              child: const Text('View'),
            ),
            SubmenuButton(
              menuChildren: [
                MenuItemButton(child: const Text('About'), onPressed: () {}),
              ],
              child: const Text('Help'),
            ),
          ],
        ),
        titleSpacing: 0,
        actions: [
          SegmentedButton<LayoutMode>(
            segments: const [
              ButtonSegment(value: LayoutMode.crop, label: Text('Crop')),
              ButtonSegment(value: LayoutMode.letterbox, label: Text('Fit')),
              ButtonSegment(value: LayoutMode.masonry, label: Text('Masonry')),
            ],
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
              onChanged: (v) => setState(() => _tileSize = v),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(_previewVisible ? Icons.view_sidebar : Icons.view_sidebar_outlined),
            tooltip: _previewVisible ? 'Hide preview' : 'Show preview',
            onPressed: () => setState(() => _previewVisible = !_previewVisible),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _onLayoutWidth(constraints.maxWidth);
                final width = _committedWidth > 0 ? _committedWidth : constraints.maxWidth;
                final cols = _columnCount(width);

                Widget grid;
                if (_layout == LayoutMode.masonry) {
                  grid = MasonryGridView.builder(
                    key: _gridKey,
                    gridDelegate: SliverSimpleGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                    ),
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    itemCount: kImagePaths.length,
                    itemBuilder: (context, index) => GalleryTile(
                      key: _tileKeys[kImagePaths[index]],
                      path: kImagePaths[index],
                      tileSize: _tileSize,
                      layout: _layout,
                      selected: _selectedPaths.contains(kImagePaths[index]),
                      onTap: () => setState(() {
                        _selectedPaths.clear();
                        _selectedPaths.add(kImagePaths[index]);
                      }),
                    ),
                  );
                } else {
                  grid = GridView.builder(
                    key: _gridKey,
                    itemCount: kImagePaths.length,
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: _tileSize,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                    ),
                    itemBuilder: (context, index) => GalleryTile(
                      key: _tileKeys[kImagePaths[index]],
                      path: kImagePaths[index],
                      tileSize: _tileSize,
                      layout: _layout,
                      selected: _selectedPaths.contains(kImagePaths[index]),
                      onTap: () => setState(() {
                        _selectedPaths.clear();
                        _selectedPaths.add(kImagePaths[index]);
                      }),
                    ),
                  );
                }

                return GestureDetector(
                  onPanStart: (d) => setState(() {
                    _dragStart = d.localPosition;
                    _dragCurrent = d.localPosition;
                  }),
                  onPanUpdate: (d) {
                    setState(() => _dragCurrent = d.localPosition);
                    _updateMarqueeSelection();
                  },
                  onPanEnd: (_) => setState(() {
                    _dragStart = null;
                    _dragCurrent = null;
                  }),
                  child: Stack(
                    children: [
                      grid,
                      if (_selectionRect != null)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _MarqueePainter(_selectionRect!),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (_previewVisible) ...[
            // Drag handle
            GestureDetector(
              onHorizontalDragUpdate: (d) => setState(() {
                _previewWidth = (_previewWidth - d.delta.dx).clamp(150, 800);
              }),
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: Container(
                  width: 6,
                  color: Colors.white12,
                ),
              ),
            ),
            // Preview pane
            SizedBox(
              width: _previewWidth,
              child: ColoredBox(
                color: Colors.black,
                child: _selectedPaths.isNotEmpty
                    ? Image.asset(_selectedPaths.first, fit: BoxFit.contain)
                    : const Center(
                        child: Text(
                          'No image selected',
                          style: TextStyle(color: Colors.white24),
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
    required this.tileSize,
    required this.layout,
    required this.selected,
    required this.onTap,
  });

  final String path;
  final double tileSize;
  final LayoutMode layout;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      path,
      fit: layout == LayoutMode.crop ? BoxFit.cover : BoxFit.contain,
      cacheWidth: layout == LayoutMode.masonry
          ? null
          : (tileSize * MediaQuery.devicePixelRatioOf(context)).ceil(),
      errorBuilder: (_, __, ___) => const ColoredBox(
        color: Colors.white10,
        child: Icon(Icons.broken_image, color: Colors.white24),
      ),
    );

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: layout == LayoutMode.masonry ? StackFit.loose : StackFit.expand,
        children: [
          layout == LayoutMode.masonry
              ? image
              : ColoredBox(color: Colors.black, child: image),
          if (selected)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.blue, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
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
        ..color = Colors.blue.withOpacity(0.15)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.blue.withOpacity(0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_MarqueePainter old) => old.rect != rect;
}
