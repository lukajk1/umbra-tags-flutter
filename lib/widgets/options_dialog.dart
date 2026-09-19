import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../ml/classifier.dart';

import 'ml_settings_dialog.dart';

const startupModels = <String, String>{
  'classifier': 'Artwork / photo classifier',
  'similarity': 'Similarity image encoder',
  'tags': 'Tag suggestion text encoder',
};

class AppOptions {
  const AppOptions({
    required this.ml,
    required this.preloadModels,
    required this.reopenLastLibrary,
    required this.receiverEnabled,
    required this.receiverPort,
  });
  final MlSettings ml;
  final Set<String> preloadModels;
  final bool reopenLastLibrary, receiverEnabled;
  final int receiverPort;
}

class OptionsDialog extends StatefulWidget {
  const OptionsDialog({
    super.key,
    required this.options,
    required this.onSave,
    required this.receiverStatus,
    required this.modelStatus,
  });
  final AppOptions options;
  final String receiverStatus;
  final Map<String, String> modelStatus;
  final Future<void> Function(AppOptions options, bool loadNow) onSave;
  @override
  State<OptionsDialog> createState() => _OptionsDialogState();
}

class _OptionsDialogState extends State<OptionsDialog> {
  late final _home = TextEditingController(text: widget.options.ml.home ?? '');
  late final _python = TextEditingController(
    text: widget.options.ml.python ?? '',
  );
  late String? _selected = widget.options.ml.modelId;
  bool _modelSelectionChanged = false;
  late double _threshold = widget.options.ml.threshold;
  late bool _assign = widget.options.ml.assignTags;
  late final _preload = Set<String>.from(widget.options.preloadModels);
  late bool _reopen = widget.options.reopenLastLibrary;
  late bool _receiverEnabled = widget.options.receiverEnabled;
  late final _port = TextEditingController(
    text: widget.options.receiverPort.toString(),
  );
  bool _saving = false;
  String? _saveError;
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
    _port.dispose();
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
    if (!mounted || generation != _generation) return;
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
          if (_selected != null) _modelSelectionChanged = true;
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
      _modelSelectionChanged = true;
      _models = [];
      _selected = null;
    });
  }

  Future<void> _save({bool loadNow = false}) async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1024 || port > 65535) {
      setState(() => _saveError = 'Enter a receiver port from 1024 to 65535.');
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await widget.onSave(
        AppOptions(
          ml: MlSettings(
            home: _home.text.trim().isEmpty ? null : _home.text.trim(),
            python: _python.text.trim().isEmpty ? null : _python.text.trim(),
            modelId: _modelSelectionChanged
                ? _selected
                : widget.options.ml.modelId,
            threshold: _threshold,
            assignTags: _assign,
          ),
          preloadModels: Set.of(_preload),
          reopenLastLibrary: _reopen,
          receiverEnabled: _receiverEnabled,
          receiverPort: port,
        ),
        loadNow,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saveError = error.toString();
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final machineLearning = SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Classifier settings control ML classify. Similarity and tag suggestions use the same ML folder and Python runtime.',
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
              hintText: 'Automatic: bundled Python or the ML folder’s .venv',
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
                      child: Text(model.name, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() {
                _selected = value;
                _modelSelectionChanged = true;
              }),
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
    );
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('Options'),
        content: SizedBox(
          width: 640,
          height: 490,
          child: Column(
            children: [
              Expanded(
                child: AbsorbPointer(
                  absorbing: _saving,
                  child: DefaultTabController(
                    length: 3,
                    child: Column(
                      children: [
                        const TabBar(
                          tabs: [
                            Tab(text: 'Startup'),
                            Tab(text: 'Machine learning'),
                            Tab(text: 'Browser extension'),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Expanded(
                          child: TabBarView(
                            children: [
                              ListView(
                                children: [
                                  CheckboxListTile(
                                    contentPadding: EdgeInsets.zero,
                                    value: _reopen,
                                    title: const Text(
                                      'Reopen the last library',
                                    ),
                                    onChanged: (v) =>
                                        setState(() => _reopen = v!),
                                  ),
                                  const Divider(),
                                  const Text(
                                    'Load these models when Umbra Tags launches:',
                                  ),
                                  for (final entry in startupModels.entries)
                                    CheckboxListTile(
                                      contentPadding: EdgeInsets.zero,
                                      value: _preload.contains(entry.key),
                                      title: Text(entry.value),
                                      subtitle: Text(
                                        widget.modelStatus[entry.value] ??
                                            'On demand',
                                      ),
                                      onChanged: (v) => setState(
                                        () => v == true
                                            ? _preload.add(entry.key)
                                            : _preload.remove(entry.key),
                                      ),
                                    ),
                                  const SizedBox(height: 8),
                                  const Text(
                                    'Unchecked models load when needed. Background indexing keeps its per-library pause/resume setting.',
                                    style: TextStyle(color: Colors.white60),
                                  ),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton(
                                      onPressed: _preload.isEmpty
                                          ? null
                                          : () => _save(loadNow: true),
                                      child: const Text(
                                        'Save and load selected now',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              machineLearning,
                              ListView(
                                children: [
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    value: _receiverEnabled,
                                    title: const Text(
                                      'Enable browser extension connection',
                                    ),
                                    subtitle: const Text(
                                      'Allow the extension to send images to this app.',
                                    ),
                                    onChanged: (v) =>
                                        setState(() => _receiverEnabled = v),
                                  ),
                                  const SizedBox(height: 16),
                                  TextField(
                                    controller: _port,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'Receiver port',
                                      helperText:
                                          'Default: 8934 · allowed: 1024–65535',
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  const Text(
                                    'Use the same port in the extension’s Connection settings. Changes take effect when you save.',
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    widget.receiverStatus,
                                    style: const TextStyle(
                                      color: Colors.white60,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_saveError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _saveError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _saving ? null : () => _save(),
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    );
  }
}
