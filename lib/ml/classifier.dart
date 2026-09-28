import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

class ClassifierModel {
  ClassifierModel(this.id, this.name, this.available, this.isDefault);
  final String id, name;
  final bool available, isDefault;
}

class ClassificationResult {
  ClassificationResult.fromJson(Map<String, dynamic> data)
    : assetId = data['assetId'] as String,
      contentHash = data['contentHash'] as String,
      modelId = data['modelId'] as String,
      modelVersion = data['modelVersion'] as String,
      scores = (data['scores'] as List)
          .map((row) => Map<String, Object?>.from(row as Map))
          .toList();
  final String assetId, contentHash, modelId, modelVersion;
  final List<Map<String, Object?>> scores;
}

/// Replace this implementation to use ONNX, a remote service, or another runtime.
/// Backends only predict. LibraryStore owns tagging and prediction persistence.
abstract interface class ImageClassifier {
  Future<List<ClassifierModel>> models();
  Future<void> loadModel(String? modelId);
  Future<List<String>> labels(String? modelId);
  Future<ClassificationResult> classify({
    required String assetId,
    required String imagePath,
    required String contentHash,
    String? modelId,
  });
  Future<void> dispose();
}

class PythonImageClassifier implements ImageClassifier {
  PythonImageClassifier({this.home, this.python});
  final String? home, python;
  Process? _process;
  Future<void>? _starting;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _nextId = 0;
  String _stderr = '';
  bool _disposed = false;
  Future<void>? _disposing;
  final _terminating = <Process, Future<void>>{};

  static String? discoverHome() {
    final override = Platform.environment['UMBRA_ML_HOME'];
    if (override != null && override.isNotEmpty) return override;
    for (final initial in [
      p.dirname(Platform.resolvedExecutable),
      Directory.current.path,
    ]) {
      var directory = initial;
      for (var i = 0; i < 12; i++) {
        for (final candidate in [
          directory,
          p.join(directory, 'umbra-tags-ml'),
        ]) {
          if (File(p.join(candidate, 'runner.py')).existsSync() &&
              File(p.join(candidate, 'models.json')).existsSync()) {
            return candidate;
          }
        }
        final parent = p.dirname(directory);
        if (parent == directory) break;
        directory = parent;
      }
    }
    return null;
  }

  Future<void> _start() async {
    if (_disposed) throw StateError('Classifier is closed.');
    if (_process != null) return;
    if (_starting != null) return _starting!;
    _starting = _launch();
    try {
      await _starting;
    } finally {
      _starting = null;
    }
  }

  Future<void> _launch() async {
    final root = home ?? discoverHome();
    if (root == null) {
      throw StateError(
        'ML folder not found. Choose umbra-tags-ml in Edit → Options → Machine learning.',
      );
    }
    final requirementsFile = File(p.join(root, 'runtime-requirements.json'));
    final requirements = requirementsFile.existsSync()
        ? jsonDecode(requirementsFile.readAsStringSync())
              as Map<String, dynamic>
        : <String, dynamic>{'runtimeId': '1'};
    final runtimeId = requirements['runtimeId'] as String;
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(runtimeId)) {
      throw StateError('Invalid ML runtime version.');
    }
    var assets = Platform.environment['UMBRA_ML_ASSETS'] ?? root;
    final hasLocalRuntime =
        Directory(p.join(root, 'python')).existsSync() ||
        Directory(p.join(root, '.venv')).existsSync();
    final developmentRuntime = Directory(p.join(root, '.venv')).existsSync();
    final localMarker = File(p.join(root, 'ml-runtime.json'));
    final localCompatible =
        hasLocalRuntime &&
        (localMarker.existsSync()
            ? (jsonDecode(localMarker.readAsStringSync())
                      as Map)['runtimeId'] ==
                  runtimeId
            : runtimeId == '1' || developmentRuntime);
    if (Platform.environment['UMBRA_ML_ASSETS'] == null &&
        !localCompatible &&
        Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'];
      if (local != null) assets = p.join(local, 'Umbra Tags', 'ML', runtimeId);
    }
    final marker = File(p.join(assets, 'ml-runtime.json'));
    if (marker.existsSync()) {
      final installed =
          jsonDecode(marker.readAsStringSync()) as Map<String, dynamic>;
      if (installed['format'] != 1 || installed['runtimeId'] != runtimeId) {
        throw StateError(
          'Install Umbra Tags ML runtime pack $runtimeId to use this app version.',
        );
      }
    } else if ((runtimeId != '1' && !developmentRuntime) || assets != root) {
      throw StateError(
        'ML runtime pack $runtimeId is missing. Install the ML pack or the full offline installer.',
      );
    }
    final bundledPython = p.join(
      assets,
      'python',
      Platform.isWindows ? 'python.exe' : 'bin/python',
    );
    final executable =
        python ??
        Platform.environment['UMBRA_ML_PYTHON'] ??
        (File(bundledPython).existsSync()
            ? bundledPython
            : p.join(
                root,
                '.venv',
                Platform.isWindows ? 'Scripts' : 'bin',
                Platform.isWindows ? 'python.exe' : 'python',
              ));
    if (!File(executable).existsSync()) {
      throw StateError(
        'ML Python environment not found: $executable. See umbra-tags-ml/README.md for setup.',
      );
    }
    _stderr = '';
    final process = await Process.start(
      executable,
      ['-u', p.join(root, 'runner.py')],
      workingDirectory: root,
      environment: {
        'PYTHONUTF8': '1',
        'HF_HUB_OFFLINE': '1',
        'TRANSFORMERS_OFFLINE': '1',
        'UMBRA_ML_ASSETS': assets,
      },
    );
    if (_disposed) {
      await _terminateProcess(process);
      return;
    }
    _process = process;
    unawaited(
      process.stdin.done.then<void>(
        (_) {},
        onError: (Object error) {
          if (identical(_process, process)) {
            _fail(error);
            unawaited(_terminateProcess(process));
          }
        },
      ),
    );
    process.stderr.transform(utf8.decoder).listen((chunk) {
      _stderr += chunk;
      if (_stderr.length > 4000) {
        _stderr = _stderr.substring(_stderr.length - 4000);
      }
    });
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            try {
              final reply = jsonDecode(line) as Map<String, dynamic>;
              final pending = _pending[reply['id']];
              if (pending == null) return;
              if (reply['ok'] == true) {
                pending.complete(
                  Map<String, dynamic>.from(reply['result'] as Map),
                );
              } else {
                pending.completeError(
                  StateError(
                    reply['error']?.toString() ?? 'Classification failed.',
                  ),
                );
              }
              _pending.remove(reply['id']);
            } catch (error) {
              _fail(error);
              unawaited(_terminateProcess(process));
            }
          },
          onError: (Object error) {
            _fail(error);
            unawaited(_terminateProcess(process));
          },
        );
    unawaited(
      process.exitCode.then((code) {
        if (identical(_process, process)) {
          _process = null;
          _fail(StateError('Classifier exited ($code). $_stderr'));
        }
      }),
    );
  }

  void _fail(Object error) {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> _request(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    await _start();
    if (_disposed || _process == null) {
      throw StateError('Classifier is closed.');
    }
    final id = ++_nextId;
    final reply = Completer<Map<String, dynamic>>();
    _pending[id] = reply;
    try {
      _process!.stdin.writeln(
        jsonEncode({'id': id, 'method': method, ...args}),
      );
      return await reply.future.timeout(const Duration(minutes: 2));
    } on TimeoutException {
      final process = _process;
      _process = null;
      _fail(StateError('Classifier timed out.'));
      if (process != null) unawaited(_terminateProcess(process));
      throw StateError('Classifier timed out. Check the ML configuration.');
    } finally {
      _pending.remove(id);
    }
  }

  Future<Map<String, dynamic>> requestTags(
    String method, [
    Map<String, Object?> args = const {},
  ]) => _request('tags.$method', args);

  /// Shared JSON-lines transport for independent embedding adapters.
  Future<Map<String, dynamic>> requestEmbedding(
    String method, [
    Map<String, Object?> args = const {},
  ]) => _request('embedding.$method', args);

  @override
  Future<List<ClassifierModel>> models() async {
    final result = await _request('models');
    return (result['models'] as List)
        .map(
          (row) => ClassifierModel(
            row['id'] as String,
            row['name'] as String,
            row['available'] == true,
            row['id'] == result['defaultModel'],
          ),
        )
        .toList();
  }

  @override
  Future<void> loadModel(String? modelId) async {
    await _request('load', {'modelId': modelId});
  }

  @override
  Future<List<String>> labels(String? modelId) async {
    final data = await _request('load', {'modelId': modelId});
    return (data['labels'] as List).cast<String>();
  }

  @override
  Future<ClassificationResult> classify({
    required String assetId,
    required String imagePath,
    required String contentHash,
    String? modelId,
  }) async => ClassificationResult.fromJson(
    await _request('classify', {
      'assetId': assetId,
      'imagePath': imagePath,
      'contentHash': contentHash,
      'modelId': modelId,
    }),
  );
  @override
  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _fail(StateError('Classifier stopped.'));
    final process = _process;
    _process = null;
    if (process != null) {
      await _terminateProcess(process);
    }
    // A process may still be starting; _launch terminates it if disposed.
    try {
      await _starting;
    } catch (_) {}
  }

  Future<void> _terminateProcess(Process process) =>
      _terminating.putIfAbsent(process, () => _terminateTree(process));

  Future<void> _terminateTree(Process process) async {
    if (Platform.isWindows) {
      // venv python.exe is a launcher on Windows. Kill its owned process tree
      // before the launcher exits, otherwise the real interpreter is orphaned.
      try {
        final result = await Process.run(
          p.join(
            Platform.environment['SystemRoot'] ?? r'C:\Windows',
            'System32',
            'taskkill.exe',
          ),
          ['/PID', '${process.pid}', '/T', '/F'],
        ).timeout(const Duration(seconds: 3));
        if (result.exitCode != 0) process.kill();
      } catch (_) {
        process.kill();
      }
    } else {
      process.kill();
    }
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
  }
}
