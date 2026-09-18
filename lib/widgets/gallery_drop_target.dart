import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

class GalleryDropTarget extends StatefulWidget {
  const GalleryDropTarget({
    super.key,
    required this.enabled,
    required this.onFiles,
    required this.child,
  });

  final bool enabled;
  final ValueChanged<List<XFile>> onFiles;
  final Widget child;

  @override
  State<GalleryDropTarget> createState() => _GalleryDropTargetState();
}

class _GalleryDropTargetState extends State<GalleryDropTarget> {
  bool _hovering = false;

  @override
  void didUpdateWidget(GalleryDropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _hovering = false;
  }

  @override
  Widget build(BuildContext context) => DropTarget(
    enable: widget.enabled,
    onDragEntered: (_) => setState(() => _hovering = true),
    onDragExited: (_) => setState(() => _hovering = false),
    onDragDone: (details) {
      setState(() => _hovering = false);
      if (!widget.enabled) return;
      final files = details.files
          .where((file) => file is! DropItemDirectory)
          .map((file) => XFile(file.path))
          .toList();
      if (files.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Drop image files here, rather than folders.'),
          ),
        );
        return;
      }
      widget.onFiles(files);
    },
    child: Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_hovering && widget.enabled)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                ),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_photo_alternate_outlined, size: 40),
                      SizedBox(height: 12),
                      Text(
                        'Drop images to import',
                        style: TextStyle(fontSize: 18),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
