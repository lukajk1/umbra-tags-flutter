import 'dart:io';
import 'package:flutter/material.dart';
import '../storage/library_store.dart';

enum TagMatchSource { semantic, classifier }

typedef ScoreTagImage =
    Future<double> Function(
      LibraryAsset asset,
      TagMatchSource source,
      String label,
    );

class TagMatchDialog extends StatefulWidget {
  const TagMatchDialog({
    super.key,
    required this.tagName,
    required this.assets,
    required this.classifierLabels,
    required this.score,
    required this.thumbnail,
    required this.onApply,
    this.classifierError,
    this.classifierThreshold = 0.8,
  });
  final String tagName;
  final List<LibraryAsset> assets;
  final List<String> classifierLabels;
  final String? classifierError;
  final double classifierThreshold;
  final ScoreTagImage score;
  final Future<String?> Function(LibraryAsset) thumbnail;
  final Future<void> Function(List<LibraryAsset>) onApply;

  @override
  State<TagMatchDialog> createState() => _TagMatchDialogState();
}

class _TagMatchDialogState extends State<TagMatchDialog> {
  TagMatchSource _source = TagMatchSource.semantic;
  String? _classLabel;
  double _semanticThreshold = 0.15;
  late double _classifierThreshold;
  final _scores = <String, double>{};
  final _selected = <String>{};
  final _errors = <String, String>{};
  final _thumbnails = <String, Future<String?>>{};
  bool _scanning = false, _saving = false, _stop = false;
  int _processed = 0;
  String? _error;

  double get _threshold => _source == TagMatchSource.classifier
      ? _classifierThreshold
      : _semanticThreshold;

  @override
  void initState() {
    super.initState();
    _classifierThreshold = widget.classifierThreshold.clamp(0, 1);
    for (final label in widget.classifierLabels) {
      if (label.trim().toLowerCase() == widget.tagName.trim().toLowerCase()) {
        _classLabel = label;
        _source = TagMatchSource.classifier;
        break;
      }
    }
    _classLabel ??= widget.classifierLabels.firstOrNull;
  }

  void _reset() {
    _scores.clear();
    _selected.clear();
    _errors.clear();
    _processed = 0;
    _error = null;
  }

  void _selectMatches() {
    _selected
      ..clear()
      ..addAll(
        _scores.entries.where((e) => e.value >= _threshold).map((e) => e.key),
      );
  }

  Future<void> _scan() async {
    setState(() {
      _reset();
      _scanning = true;
      _stop = false;
    });
    final label = _source == TagMatchSource.classifier
        ? _classLabel!
        : widget.tagName;
    try {
      for (final asset in widget.assets) {
        if (!mounted || _stop) break;
        try {
          final value = await widget.score(asset, _source, label);
          if (!value.isFinite ||
              value < -1 ||
              value > 1 ||
              (_source == TagMatchSource.classifier && value < 0)) {
            throw StateError('The model returned an invalid score.');
          }
          if (!mounted) return;
          setState(() {
            _scores[asset.id] = value;
            if (value >= _threshold) _selected.add(asset.id);
          });
        } catch (error) {
          if (!mounted) return;
          setState(() => _errors[asset.id] = error.toString());
          // Avoid repeatedly calling a broken backend across a large library.
          if (_scores.isEmpty && _errors.length >= 3) {
            _stop = true;
            _error =
                'Scan stopped after three failures. Check the image errors and ML settings.';
          }
        }
        if (!mounted) return;
        setState(() => _processed++);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _apply() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onApply(
        widget.assets.where((a) => _selected.contains(a.id)).toList(),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _saving = false;
        });
      }
    }
  }

  String _scoreLabel(double score) => _source == TagMatchSource.classifier
      ? '${(score * 100).toStringAsFixed(1)}%'
      : 'Rank score ${score.toStringAsFixed(3)}';

  @override
  Widget build(BuildContext context) {
    final locked = _scanning || _saving;
    final rows =
        widget.assets
            .where(
              (a) => _scores.containsKey(a.id) || _errors.containsKey(a.id),
            )
            .toList()
          ..sort(
            (a, b) => (_scores[b.id] ?? -2).compareTo(_scores[a.id] ?? -2),
          );
    return PopScope(
      canPop: !locked,
      child: AlertDialog(
        title: Text('Find images for “${widget.tagName}”'),
        content: SizedBox(
          width: 760,
          height: 590,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${widget.assets.length} available images without this tag. Archived images are excluded.',
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<TagMatchSource>(
                initialValue: _source,
                decoration: const InputDecoration(labelText: 'Match using'),
                items: [
                  const DropdownMenuItem(
                    value: TagMatchSource.semantic,
                    child: Text(
                      'Tag suggestion model — text / image similarity',
                    ),
                  ),
                  if (widget.classifierLabels.isNotEmpty)
                    const DropdownMenuItem(
                      value: TagMatchSource.classifier,
                      child: Text('Trained classifier'),
                    ),
                ],
                onChanged: locked
                    ? null
                    : (value) => setState(() {
                        _source = value!;
                        _reset();
                      }),
              ),
              if (_source == TagMatchSource.classifier) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _classLabel,
                  decoration: const InputDecoration(
                    labelText: 'Classifier label to match',
                  ),
                  items: widget.classifierLabels
                      .map(
                        (label) =>
                            DropdownMenuItem(value: label, child: Text(label)),
                      )
                      .toList(),
                  onChanged: locked
                      ? null
                      : (value) => setState(() {
                          _classLabel = value;
                          _reset();
                        }),
                ),
              ],
              if (widget.classifierError != null)
                Text(
                  'Classifier unavailable: ${widget.classifierError}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: Text('Minimum ${_scoreLabel(_threshold)}')),
                  TextButton(
                    onPressed: locked ? null : () => setState(_selectMatches),
                    child: const Text('Select matches'),
                  ),
                  TextButton(
                    onPressed: locked ? null : () => setState(_selected.clear),
                    child: const Text('Clear selection'),
                  ),
                ],
              ),
              Slider(
                value: _threshold,
                min: _source == TagMatchSource.classifier ? 0 : -1,
                max: 1,
                divisions: _source == TagMatchSource.classifier ? 100 : 400,
                label: _scoreLabel(_threshold),
                onChanged: locked
                    ? null
                    : (value) => setState(() {
                        if (_source == TagMatchSource.classifier) {
                          _classifierThreshold = value;
                        } else {
                          _semanticThreshold = value;
                        }
                        _selectMatches();
                      }),
              ),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: locked || widget.assets.isEmpty ? null : _scan,
                    icon: const Icon(Icons.auto_awesome, size: 18),
                    label: Text(
                      _processed == 0 ? 'Scan library' : 'Scan again',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '$_processed / ${widget.assets.length} scanned · ${_selected.length} selected · ${_errors.length} failed',
                    ),
                  ),
                  if (_scanning)
                    TextButton(
                      onPressed: _stop
                          ? null
                          : () => setState(() => _stop = true),
                      child: Text(_stop ? 'Stopping…' : 'Stop'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (_scanning)
                LinearProgressIndicator(
                  value: widget.assets.isEmpty
                      ? 0
                      : _processed / widget.assets.length,
                ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              Expanded(
                child: rows.isEmpty
                    ? const Center(
                        child: Text(
                          'Scan to preview matches, then add the selected images.',
                        ),
                      )
                    : ListView.builder(
                        itemCount: rows.length,
                        itemBuilder: (_, index) {
                          final asset = rows[index];
                          final score = _scores[asset.id];
                          return CheckboxListTile(
                            key: ValueKey(asset.id),
                            value: _selected.contains(asset.id),
                            onChanged: locked || score == null
                                ? null
                                : (value) => setState(() {
                                    if (value == true) {
                                      _selected.add(asset.id);
                                    } else {
                                      _selected.remove(asset.id);
                                    }
                                  }),
                            secondary: SizedBox(
                              width: 54,
                              height: 54,
                              child: FutureBuilder<String?>(
                                future: _thumbnails.putIfAbsent(
                                  asset.id,
                                  () => widget.thumbnail(asset),
                                ),
                                builder: (_, snapshot) => snapshot.data == null
                                    ? const Icon(Icons.image_outlined)
                                    : Image.file(
                                        File(snapshot.data!),
                                        fit: BoxFit.contain,
                                        cacheWidth: 108,
                                        errorBuilder: (_, error, stack) =>
                                            const Icon(
                                              Icons.broken_image_outlined,
                                            ),
                                      ),
                              ),
                            ),
                            title: Text(
                              asset.originalFilename,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              score == null
                                  ? _errors[asset.id]!
                                  : _scoreLabel(score),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
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
            onPressed: locked ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: locked || _selected.isEmpty ? null : _apply,
            child: Text(
              _saving ? 'Adding…' : 'Add ${_selected.length} images to tag',
            ),
          ),
        ],
      ),
    );
  }
}
