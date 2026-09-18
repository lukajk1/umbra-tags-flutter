import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../ml/classifier.dart';

class MlSettings {
  const MlSettings({
    this.home,
    this.python,
    this.modelId,
    this.threshold = 0.8,
    this.assignTags = true,
  });
  final String? home, python, modelId;
  final double threshold;
  final bool assignTags;
}

class MlSettingsDialog extends StatefulWidget {
  const MlSettingsDialog({super.key, required this.settings});
  final MlSettings settings;
  @override
  State<MlSettingsDialog> createState() => _MlSettingsDialogState();
}

class _MlSettingsDialogState extends State<MlSettingsDialog> {
  late final _home = TextEditingController(
    text: widget.settings.home ?? PythonImageClassifier.discoverHome() ?? '',
  );
  late final _python = TextEditingController(
    text: widget.settings.python ?? '',
  );
  late String? _selected = widget.settings.modelId;
  late double _threshold = widget.settings.threshold;
  late bool _assign = widget.settings.assignTags;
  List<ClassifierModel> _models = [];
  String? _error;
  bool _loading = false;
  PythonImageClassifier? _probe;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _generation++;
    _probe?.dispose();
    _home.dispose();
    _python.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    await _probe?.dispose();
    final probe = PythonImageClassifier(
      home: _home.text.trim().isEmpty ? null : _home.text.trim(),
      python: _python.text.trim().isEmpty ? null : _python.text.trim(),
    );
    _probe = probe;
    try {
      final models = await probe.models();
      if (!mounted || generation != _generation) return;
      setState(() {
        _models = models.where((model) => model.available).toList();
        if (!_models.any((model) => model.id == _selected)) {
          _selected =
              _models.where((model) => model.isDefault).firstOrNull?.id ??
              _models.firstOrNull?.id;
        }
        if (_models.isEmpty) {
          _error = 'No checkpoint files found in this ML folder.';
        }
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _models = [];
          _error = error.toString();
        });
      }
    } finally {
      await probe.dispose();
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _invalidate() {
    setState(() {
      _models = [];
      _selected = null;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('ML settings'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Run a local classifier and optionally apply its best label as a tag. Existing tags are kept.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _home,
              enabled: !_loading,
              onChanged: (_) => _invalidate(),
              decoration: InputDecoration(
                labelText: 'ML folder',
                hintText: 'umbra-tags-ml',
                suffixIcon: IconButton(
                  tooltip: 'Choose ML folder',
                  onPressed: _loading
                      ? null
                      : () async {
                          final folder = await getDirectoryPath(
                            initialDirectory: _home.text.isEmpty
                                ? null
                                : _home.text,
                          );
                          if (folder != null && mounted) {
                            _home.text = folder;
                            _invalidate();
                            await _refresh();
                          }
                        },
                  icon: const Icon(Icons.folder_open),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _python,
              enabled: !_loading,
              onChanged: (_) => _invalidate(),
              decoration: const InputDecoration(
                labelText: 'Python executable (optional)',
                hintText: 'Defaults to the ML folder’s .venv',
              ),
            ),
            TextButton.icon(
              onPressed: _loading ? null : _refresh,
              icon: const Icon(Icons.refresh),
              label: Text(_loading ? 'Loading models…' : 'Reload models'),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (_models.isNotEmpty)
              DropdownButton<String>(
                isExpanded: true,
                value: _selected,
                items: _models
                    .map(
                      (model) => DropdownMenuItem(
                        value: model.id,
                        child: Text(
                          model.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _selected = value),
              ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _assign,
              title: const Text('Automatically assign confident predictions'),
              subtitle: const Text(
                'Creates missing tags. Lower-confidence results stay as predictions.',
              ),
              onChanged: (value) => setState(() => _assign = value!),
            ),
            Text('Minimum confidence: ${(_threshold * 100).round()}%'),
            Slider(
              value: _threshold,
              divisions: 100,
              label: '${(_threshold * 100).round()}%',
              onChanged: _assign
                  ? (value) => setState(() => _threshold = value)
                  : null,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _loading || _models.isEmpty
            ? null
            : () => Navigator.pop(
                context,
                MlSettings(
                  home: _home.text.trim().isEmpty ? null : _home.text.trim(),
                  python: _python.text.trim().isEmpty
                      ? null
                      : _python.text.trim(),
                  modelId: _selected,
                  threshold: _threshold,
                  assignTags: _assign,
                ),
              ),
        child: const Text('Save'),
      ),
    ],
  );
}
