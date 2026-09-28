import 'dart:io';
import 'package:flutter/material.dart';
import '../storage/library_store.dart';
import '../storage/tag_repository.dart';

class HierarchyMatch {
  const HierarchyMatch(
    this.asset,
    this.parent,
    this.child,
    this.score,
    this.best,
  );
  final LibraryAsset asset;
  final LibraryTag parent, child;
  final double score;
  final bool best;
  String get key => '${asset.id}/${child.id}';
  bool get assigned => asset.tagIds.contains(child.id);
}

class HierarchyDialog extends StatefulWidget {
  const HierarchyDialog({
    super.key,
    required this.assets,
    required this.skipped,
    required this.find,
    required this.thumbnail,
    required this.apply,
  });
  final List<LibraryAsset> assets;
  final int skipped;
  final Future<List<HierarchyMatch>> Function(LibraryAsset) find;
  final Future<String?> Function(LibraryAsset) thumbnail;
  final Future<void> Function(Map<String, List<String>>) apply;
  @override
  State<HierarchyDialog> createState() => _HierarchyDialogState();
}

class _HierarchyDialogState extends State<HierarchyDialog> {
  final _matches = <HierarchyMatch>[];
  final _selected = <String>{};
  final _errors = <String>[];
  final _thumbnails = <String, Future<String?>>{};
  bool _running = true, _stop = false, _saving = false;
  int _done = 0;
  double _cutoff = 0.15;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scan();
    });
  }

  void _chooseBest() {
    _selected.clear();
    for (final match in _matches) {
      if (match.best && !match.assigned && match.score >= _cutoff) {
        _selected.add(match.key);
      }
    }
  }

  Future<void> _scan() async {
    var consecutiveFailures = 0;
    for (final asset in widget.assets) {
      if (!mounted || _stop) break;
      try {
        final matches = await widget.find(asset);
        if (!mounted) return;
        setState(() {
          _matches.addAll(matches);
          _chooseBest();
        });
        consecutiveFailures = 0;
      } catch (error) {
        if (!mounted) return;
        setState(() => _errors.add('${asset.originalFilename}: $error'));
        if (++consecutiveFailures >= 3) _stop = true;
      }
      if (!mounted) return;
      setState(() => _done++);
    }
    if (mounted) setState(() => _running = false);
  }

  Future<void> _apply() async {
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final accepted = <String, List<String>>{};
    for (final match in _matches) {
      if (_selected.contains(match.key)) {
        accepted.putIfAbsent(match.asset.id, () => []).add(match.child.name);
      }
    }
    try {
      await widget.apply(accepted);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveError = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = _running || _saving;
    return PopScope(
      canPop: !locked,
      child: AlertDialog(
        title: const Text('AI refine tags'),
        content: SizedBox(
          width: 740,
          height: 540,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Compare direct children of existing tags. Parents are kept. ${widget.skipped} images skipped (no parent tag or unavailable).',
              ),
              const SizedBox(height: 12),
              Text(
                '$_done / ${widget.assets.length} images reviewed · ${_selected.length} tag additions',
              ),
              if (_running) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: widget.assets.isEmpty
                      ? 0
                      : _done / widget.assets.length,
                ),
                TextButton(
                  onPressed: _stop ? null : () => setState(() => _stop = true),
                  child: Text(_stop ? 'Stopping after current image…' : 'Stop'),
                ),
              ],
              Text(
                'Best child per parent · minimum rank score ${_cutoff.toStringAsFixed(3)}',
              ),
              Slider(
                value: _cutoff,
                min: -1,
                max: 1,
                divisions: 400,
                onChanged: locked
                    ? null
                    : (value) => setState(() {
                        _cutoff = value;
                        _chooseBest();
                      }),
              ),
              if (_errors.isNotEmpty)
                ExpansionTile(
                  title: Text('${_errors.length} images failed'),
                  children: [
                    SizedBox(
                      height: 90,
                      child: SingleChildScrollView(
                        child: SelectableText(_errors.join('\n')),
                      ),
                    ),
                  ],
                ),
              if (_saveError != null)
                Text(
                  _saveError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              Expanded(
                child: _matches.isEmpty
                    ? Center(
                        child: Text(
                          _running
                              ? 'Comparing child tags…'
                              : 'No child-tag suggestions found.',
                        ),
                      )
                    : ListView.builder(
                        itemCount: _matches.length,
                        itemBuilder: (_, index) {
                          final match = _matches[index];
                          return CheckboxListTile(
                            key: ValueKey(match.key),
                            value:
                                match.assigned || _selected.contains(match.key),
                            onChanged: locked || match.assigned
                                ? null
                                : (value) => setState(() {
                                    if (value == true) {
                                      _selected.add(match.key);
                                    } else {
                                      _selected.remove(match.key);
                                    }
                                  }),
                            secondary: SizedBox(
                              width: 50,
                              height: 50,
                              child: FutureBuilder<String?>(
                                future: _thumbnails.putIfAbsent(
                                  match.asset.id,
                                  () => widget.thumbnail(match.asset),
                                ),
                                builder: (_, snapshot) => snapshot.data == null
                                    ? const Icon(Icons.image_outlined)
                                    : Image.file(
                                        File(snapshot.data!),
                                        fit: BoxFit.contain,
                                        cacheWidth: 100,
                                        errorBuilder: (_, error, stack) =>
                                            const Icon(
                                              Icons.broken_image_outlined,
                                            ),
                                      ),
                              ),
                            ),
                            title: Text(
                              '${match.parent.name} → ${match.child.name}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${match.asset.originalFilename}\nRank score ${match.score.toStringAsFixed(3)}${match.assigned ? ' · Already assigned' : ''}',
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
              _saving ? 'Applying…' : 'Apply ${_selected.length} tag additions',
            ),
          ),
        ],
      ),
    );
  }
}
