import 'dart:io';
import 'package:flutter/material.dart';
import '../ml/tag_suggester.dart';
import '../storage/library_store.dart';
import '../storage/tag_repository.dart';

class TagSuggestionsPanel extends StatefulWidget {
  const TagSuggestionsPanel({
    super.key,
    required this.assets,
    required this.tags,
    required this.onSuggest,
    required this.onChanged,
    required this.accepted,
    required this.thumbnail,
    required this.saving,
  });
  final List<LibraryAsset> assets;
  final List<LibraryTag> tags;
  final Future<List<TagSuggestion>> Function(LibraryAsset) onSuggest;
  final Future<String?> Function(LibraryAsset) thumbnail;
  final Map<String, Set<String>> accepted;
  final VoidCallback onChanged;
  final bool saving;
  @override
  State<TagSuggestionsPanel> createState() => _TagSuggestionsPanelState();
}

class _TagSuggestionsPanelState extends State<TagSuggestionsPanel>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  int _index = 0, _completed = 0, _requested = 0;
  bool _running = false, _cancel = false;
  final _results = <String, List<TagSuggestion>>{};
  final _errors = <String, String>{};
  final _thumbnails = <String, Future<String?>>{};
  Future<void> _suggest(bool all) async {
    final assets = all ? widget.assets : [widget.assets[_index]];
    setState(() {
      _running = true;
      _cancel = false;
      _completed = 0;
      _requested = assets.length;
    });
    for (final asset in assets) {
      if (!mounted || _cancel) break;
      try {
        final results = await widget.onSuggest(asset);
        if (!mounted) return;
        setState(() {
          _results[asset.id] = results;
          _errors.remove(asset.id);
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _errors[asset.id] = e.toString());
      }
      if (!mounted) return;
      setState(() => _completed++);
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final asset = widget.assets[_index];
    final existing = widget.tags
        .where((t) => asset.tagIds.contains(t.id))
        .map((t) => t.name.toLowerCase())
        .toSet();
    final accepted = widget.accepted.putIfAbsent(asset.id, () => {});
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: _index > 0 ? () => setState(() => _index--) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                '${_index + 1} / ${widget.assets.length} · ${asset.originalFilename}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              onPressed: _index + 1 < widget.assets.length
                  ? () => setState(() => _index++)
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        SizedBox(
          height: 100,
          child: FutureBuilder<String?>(
            future: _thumbnails.putIfAbsent(
              asset.id,
              () => widget.thumbnail(asset),
            ),
            builder: (context, snapshot) => snapshot.data == null
                ? const Icon(Icons.image_outlined)
                : Image.file(
                    File(snapshot.data!),
                    fit: BoxFit.contain,
                    cacheHeight: 200,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.broken_image_outlined),
                  ),
          ),
        ),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: _running || widget.saving
                  ? null
                  : () => _suggest(false),
              icon: const Icon(Icons.auto_awesome, size: 16),
              label: const Text('Suggest tags'),
            ),
            if (widget.assets.length > 1)
              TextButton(
                onPressed: _running || widget.saving
                    ? null
                    : () => _suggest(true),
                child: const Text('Suggest for all'),
              ),
            if (_running)
              TextButton(
                onPressed: () => setState(() => _cancel = true),
                child: Text(_cancel ? 'Stopping…' : 'Stop'),
              ),
          ],
        ),
        if (_running)
          LinearProgressIndicator(
            value: _requested == 0 ? null : _completed / _requested,
          ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Text(
            'Review possible tags below. Checked suggestions apply only to this image when you click Apply tags.',
            style: TextStyle(fontSize: 12, color: Colors.white60),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              if (_errors[asset.id] != null)
                SelectableText(
                  _errors[asset.id]!,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              if (!_results.containsKey(asset.id) &&
                  !_errors.containsKey(asset.id))
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Click Suggest tags to analyze this image.'),
                ),
              for (final suggestion in _results[asset.id] ?? <TagSuggestion>[])
                CheckboxListTile(
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(suggestion.label),
                  subtitle: Text(
                    existing.contains(suggestion.label.toLowerCase())
                        ? 'Already assigned'
                        : 'Rank score ${suggestion.score.toStringAsFixed(3)}',
                  ),
                  value:
                      existing.contains(suggestion.label.toLowerCase()) ||
                      accepted.contains(suggestion.label),
                  onChanged:
                      widget.saving ||
                          existing.contains(suggestion.label.toLowerCase())
                      ? null
                      : (value) {
                          setState(
                            () => value == true
                                ? accepted.add(suggestion.label)
                                : accepted.remove(suggestion.label),
                          );
                          widget.onChanged();
                        },
                ),
            ],
          ),
        ),
      ],
    );
  }
}
