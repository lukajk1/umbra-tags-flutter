import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Lets the user pick which images in a folder (Downloads) to import.
/// Pops with the chosen paths, or null when cancelled.
class DownloadsImportDialog extends StatefulWidget {
  const DownloadsImportDialog({
    super.key,
    required this.folder,
    required this.files,
    required this.onOpen,
    required this.accent,
  });

  final String folder;

  /// Newest first.
  final List<File> files;
  final ValueChanged<String> onOpen;
  final Color accent;

  @override
  State<DownloadsImportDialog> createState() => _DownloadsImportDialogState();
}

class _DownloadsImportDialogState extends State<DownloadsImportDialog> {
  final Set<String> _selected = {};

  void _toggle(String path) => setState(
    () =>
        _selected.contains(path) ? _selected.remove(path) : _selected.add(path),
  );

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.devicePixelRatioOf(context);
    final count = _selected.length;
    return AlertDialog(
      title: const Text('Import from Downloads'),
      content: SizedBox(
        width: 900,
        height: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.files.length} images in ${widget.folder}, newest first. '
              'Click to select, double-click to open. Imported files move to '
              'the Recycle Bin.',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: Text('$count selected')),
                TextButton(
                  onPressed: () => setState(
                    () => _selected.addAll(widget.files.map((f) => f.path)),
                  ),
                  child: const Text('Select all'),
                ),
                TextButton(
                  onPressed: count == 0
                      ? null
                      : () => setState(_selected.clear),
                  child: const Text('Select none'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 170,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.82,
                ),
                itemCount: widget.files.length,
                itemBuilder: (context, index) {
                  final path = widget.files[index].path;
                  final selected = _selected.contains(path);
                  return GestureDetector(
                    onTap: () => _toggle(path),
                    onDoubleTap: () => widget.onOpen(path),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ColoredBox(
                                  color: Colors.white10,
                                  child: Image.file(
                                    File(path),
                                    fit: BoxFit.cover,
                                    cacheWidth: (170 * scale).ceil(),
                                    filterQuality: FilterQuality.medium,
                                    errorBuilder: (_, _, _) => const Center(
                                      child: Icon(
                                        Icons.broken_image_outlined,
                                        color: Colors.white24,
                                      ),
                                    ),
                                  ),
                                ),
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: selected
                                          ? widget.accent
                                          : Colors.transparent,
                                      width: 3,
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: 4,
                                  left: 4,
                                  child: Icon(
                                    selected
                                        ? Icons.check_circle
                                        : Icons.radio_button_unchecked,
                                    color: selected
                                        ? widget.accent
                                        : Colors.white70,
                                    shadows: const [
                                      Shadow(
                                        blurRadius: 4,
                                        color: Colors.black,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            p.basename(path),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: count == 0
              ? null
              : () => Navigator.pop(
                  context,
                  // Keep the listing order (newest first) for the import.
                  [
                    for (final file in widget.files)
                      if (_selected.contains(file.path)) file.path,
                  ],
                ),
          child: Text(count == 0 ? 'Import' : 'Import $count'),
        ),
      ],
    );
  }
}
