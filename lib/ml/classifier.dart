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

  static String? discoverHome() {
    final override = Platform.environment['UMBRA_ML_HOME'];
    if (override != null && override.isNotEmpty) return override;
    for (final initial in [
      Directory.current.path,
      p.dirname(Platform.resolvedExecutable),
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
        'ML folder not found. Choose umbra-tags-ml in Edit → ML settings.',
      );
    }
    final bundledPython = p.join(
      root,
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
      },
    );
    if (_disposed) {
      process.kill();
      return;
    }
    _process = process;
    unawaited(
      process.stdin.done.then<void>(
        (_) {},
        onError: (Object error) {
          if (identical(_process, process)) {
            _fail(error);
            process.kill();
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
              process.kill();
            }
          },
          onError: (Object error) {
            _fail(error);
            process.kill();
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
      process?.kill();
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
  Future<void> dispose() async {
    _disposed = true;
    _fail(StateError('Classifier stopped.'));
    final process = _process;
    _process = null;
    if (process != null) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
    }
  }
}
