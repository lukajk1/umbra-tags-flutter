import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../ml/similarity_controller.dart';
import '../storage/library_store.dart';

class SimilarityStatus extends StatelessWidget {
  const SimilarityStatus({super.key, required this.controller});
  final SimilarityController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: controller.error ?? controller.summary,
          child: TextButton.icon(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => _IndexDetails(controller: controller),
            ),
            icon: Icon(
              controller.error == null
                  ? Icons.image_search
                  : Icons.warning_amber,
              size: 18,
            ),
            label: SizedBox(
              width: 205,
              child: Text(
                controller.summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: controller.enabled && controller.error == null
              ? 'Pause indexing after this image'
              : 'Resume indexing',
          onPressed: () => controller.setEnabled(
            !controller.enabled || controller.error != null,
          ),
          icon: Icon(
            controller.enabled && controller.error == null
                ? Icons.pause
                : Icons.play_arrow,
            size: 18,
          ),
        ),
      ],
    ),
  );
}

class _IndexDetails extends StatelessWidget {
  const _IndexDetails({required this.controller});
  final SimilarityController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => AlertDialog(
      title: const Text('Similarity index'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(controller.summary),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: controller.total == 0
                    ? 0
                    : controller.ready / controller.total,
              ),
              const SizedBox(height: 12),
              const Text(
                'Indexes non-archived, available images in this library. New imports join the queue automatically. Your images stay on this computer.',
              ),
              if (controller.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SelectableText(controller.error!),
                ),
              if (controller.failed > 0)
                FutureBuilder<List<Map<String, Object?>>>(
                  future: controller.failures(),
                  builder: (context, snapshot) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: (snapshot.data ?? [])
                        .map(
                          (row) => Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              '${row['original_filename']}: ${row['error']}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (controller.failed > 0 || controller.error != null)
          TextButton(
            onPressed: () async {
              await controller.retryFailures();
            },
            child: const Text('Retry failed'),
          ),
        TextButton(
          onPressed: () => controller.setEnabled(
            !controller.enabled || controller.error != null,
          ),
          child: Text(
            controller.enabled && controller.error == null ? 'Pause' : 'Resume',
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class SimilarityDialog extends StatefulWidget {
  const SimilarityDialog({
    super.key,
    required this.controller,
    required this.source,
    required this.onOpen,
  });
  final SimilarityController controller;
  final LibraryAsset source;
  final ValueChanged<LibraryAsset> onOpen;
  @override
  State<SimilarityDialog> createState() => _SimilarityDialogState();
}

class _SimilarityDialogState extends State<SimilarityDialog> {
  List<Map<String, Object?>> _matches = [];
  final _thumbnails = <String, Future<String?>>{};
  Timer? _timer;
  bool _prepared = false, _searching = false;
  int _revision = -1;
  String? _error;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _prepare();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_prepared &&
        _timer == null &&
        _revision != widget.controller.revision) {
      _timer = Timer(const Duration(milliseconds: 750), () {
        _timer = null;
        _search();
      });
    }
  }

  Future<void> _prepare() async {
    try {
      await widget.controller.ensure(widget.source);
      if (!mounted) return;
      _prepared = true;
      await _search();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _search() async {
    if (_searching || !mounted) return;
    _searching = true;
    final revision = widget.controller.revision;
    try {
      final matches = await widget.controller.search(widget.source);
      if (mounted) {
        setState(() {
          _matches = matches;
          _revision = revision;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      _searching = false;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Dialog(
      child: SizedBox(
        width: 980,
        height: MediaQuery.sizeOf(context).height * 0.82,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Similar to ${widget.source.originalFilename}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Text(
                'Searching ${controller.ready} of ${controller.total} images indexed · closest 50 matches · cosine similarity',
              ),
              SimilarityStatus(controller: controller),
              const SizedBox(height: 12),
              if (_error != null)
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              Expanded(
                child: !_prepared && _error == null
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 12),
                            Text('Preparing this image…'),
                          ],
                        ),
                      )
                    : _matches.isEmpty
                    ? Center(
                        child: Text(
                          controller.ready < controller.total
                              ? 'Matches will appear as more images are indexed.'
                              : 'No other indexed images in this library.',
                        ),
                      )
                    : GridView.builder(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 220,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childAspectRatio: 0.85,
                            ),
                        itemCount: _matches.length,
                        itemBuilder: (context, index) {
                          final row = _matches[index];
                          final asset = LibraryAsset.fromMap(row);
                          return Tooltip(
                            message:
                                '${asset.originalFilename}\nDouble-click to open in external viewer',
                            child: GestureDetector(
                              onDoubleTap: () => widget.onOpen(asset),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: FutureBuilder<String?>(
                                      future: _thumbnails.putIfAbsent(
                                        asset.id,
                                        () =>
                                            controller.library.thumbnail(asset),
                                      ),
                                      builder: (context, snapshot) =>
                                          snapshot.data == null
                                          ? const ColoredBox(
                                              color: Colors.white10,
                                              child: Icon(Icons.image_outlined),
                                            )
                                          : Image.file(
                                              File(snapshot.data!),
                                              fit: BoxFit.contain,
                                              cacheWidth: 440,
                                              errorBuilder: (_, _, _) =>
                                                  const Icon(
                                                    Icons.broken_image_outlined,
                                                  ),
                                            ),
                                    ),
                                  ),
                                  Text(
                                    asset.originalFilename,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    'Similarity ${(row['score'] as double).toStringAsFixed(3)}',
                                    style: const TextStyle(
                                      color: Colors.white60,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (_error != null)
                TextButton(
                  onPressed: () async {
                    setState(() => _error = null);
                    await controller.retryFailures();
                    if (mounted) await _prepare();
                  },
                  child: const Text('Retry'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
