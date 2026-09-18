import 'dart:async';
import 'package:flutter/foundation.dart';
import '../storage/library_store.dart';
import 'image_embedder.dart';

class SimilarityController extends ChangeNotifier {
  SimilarityController(
    this.library,
    this.embedder, {
    required this.shouldYield,
  });
  final LibraryStore library;
  final ImageEmbedder embedder;
  final bool Function() shouldYield;
  EmbeddingModel? model;
  int ready = 0, total = 0, failed = 0;
  int revision = 0;
  bool enabled = true, working = false, _closed = false, _loaded = false;
  String? error;
  String activity = 'Preparing similarity index…';
  Timer? _timer;
  Future<void>? _loop, _starting, _stopping;
  final _priority = <String, LibraryAsset>{};
  final _waiting = <String, Completer<void>>{};

  String get summary => error != null
      ? 'Similarity indexing needs attention'
      : working
      ? '$activity · $ready / $total indexed'
      : '${enabled ? 'Similarity' : 'Similarity paused'} · $ready / $total indexed${failed > 0 ? ' · $failed failed' : ''}';

  Future<void> start() => _starting ??= _initialize();

  /// Preloading does not enable a paused indexing queue or modify images.
  Future<void> warmUp() async {
    await start();
    if (_closed) throw StateError('Library closed.');
    if (error != null) throw StateError(error!);
    if (!_loaded) await embedder.load();
    if (_closed) return;
    _loaded = true;
  }

  Future<void> _initialize() async {
    try {
      enabled = await library.similarity({'op': 'settings'}) as bool;
      if (_closed) return;
      model = await embedder.info();
      if (_closed) return;
      await library.similarity({
        'op': 'register',
        'key': model!.key,
        'modelId': model!.name,
        'revision': model!.revision,
        'preprocessing': model!.preprocessing,
        'dimension': model!.dimension,
      });
      if (_closed) return;
      await _refresh();
      if (_closed) return;
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => kick());
      kick();
    } catch (e) {
      if (!_closed) {
        error = e.toString();
        notifyListeners();
      }
    }
  }

  Future<void> _refresh() async {
    if (_closed || model == null) return;
    final state =
        await library.similarity({'op': 'state', 'key': model!.key}) as Map;
    if (_closed) return;
    final changed =
        ready != state['ready'] ||
        total != state['total'] ||
        failed != state['failed'];
    ready = state['ready'] as int;
    total = state['total'] as int;
    failed = state['failed'] as int;
    if (changed) revision++;
    notifyListeners();
  }

  void kick() {
    if (_closed || model == null || _loop != null || error != null) return;
    _loop = _pump().whenComplete(() => _loop = null);
  }

  Future<void> _pump() async {
    try {
      while (!_closed) {
        LibraryAsset? asset;
        final urgent = _priority.isNotEmpty;
        if (urgent) {
          asset = _priority.values.first;
          _priority.remove(asset.id);
        } else {
          if (!enabled || shouldYield()) break;
          final row = await library.similarity({
            'op': 'next',
            'key': model!.key,
          });
          if (_closed) return;
          if (row == null) break;
          asset = LibraryAsset.fromMap(Map<String, Object?>.from(row as Map));
        }
        if (await library.similarity({
              'op': 'has',
              'key': model!.key,
              'assetId': asset.id,
            }) ==
            true) {
          _waiting.remove(asset.id)?.complete();
          continue;
        }
        if (_closed) return;
        working = true;
        activity = _loaded
            ? 'Indexing images'
            : 'Loading bundled similarity model…';
        notifyListeners();
        // Runtime/model failures stop the queue; individual bad images do not.
        if (!_loaded) {
          await embedder.load();
          _loaded = true;
        }
        if (_closed) return;
        try {
          final vector = await embedder.embed(
            asset,
            library.absolutePath(asset.relativePath),
          );
          if (_closed) return;
          final saved = await library.similarity({
            'op': 'save',
            'key': model!.key,
            'assetId': asset.id,
            'hash': asset.contentHash,
            'vector': vector,
          });
          if (saved != true) throw StateError('Image was changed or deleted.');
          _waiting.remove(asset.id)?.complete();
          revision++;
        } catch (e) {
          if (_closed) return;
          await library.similarity({
            'op': 'save',
            'key': model!.key,
            'assetId': asset.id,
            'hash': asset.contentHash,
            'error': e.toString(),
          });
          _waiting.remove(asset.id)?.completeError(e);
        }
        await _refresh();
        // Give interactive catalog work a chance between each image.
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await _refresh();
    } catch (e) {
      if (!_closed) {
        error = e.toString();
        for (final waiter in _waiting.values) {
          waiter.completeError(e);
        }
        _waiting.clear();
        _priority.clear();
      }
    } finally {
      working = false;
      if (!_closed) notifyListeners();
    }
  }

  Future<void> ensure(LibraryAsset asset) async {
    await start();
    if (_closed) throw StateError('Library closed.');
    if (error != null) throw StateError(error!);
    if (await library.similarity({
          'op': 'has',
          'key': model!.key,
          'assetId': asset.id,
        }) ==
        true) {
      return;
    }
    if (_closed) throw StateError('Library closed.');
    final waiter = _waiting.putIfAbsent(asset.id, () => Completer<void>());
    _priority[asset.id] = asset;
    // A finishing pump may still own _loop; the timer also wakes pending work.
    kick();
    await waiter.future;
  }

  Future<List<Map<String, Object?>>> search(LibraryAsset asset) async {
    if (_closed || model == null) return [];
    return (await library.similarity({
              'op': 'search',
              'key': model!.key,
              'assetId': asset.id,
            })
            as List)
        .map((r) => Map<String, Object?>.from(r as Map))
        .toList();
  }

  Future<void> setEnabled(bool value) async {
    if (_closed) return;
    try {
      enabled = value;
      await library.similarity({'op': 'settings', 'enabled': value});
      if (_closed) return;
      if (value && error != null) {
        error = null;
        _loaded = false;
        if (model == null) {
          _starting = null;
          await start();
        }
      }
      kick();
      if (!_closed) notifyListeners();
    } catch (e) {
      if (!_closed) {
        error = e.toString();
        notifyListeners();
      }
    }
  }

  Future<void> retryFailures() async {
    if (model != null && !_closed) {
      await library.similarity({'op': 'retry', 'key': model!.key});
    }
    await setEnabled(true);
  }

  Future<List<Map<String, Object?>>> failures() async =>
      model == null || _closed
      ? []
      : (await library.similarity({'op': 'errors', 'key': model!.key}) as List)
            .map((r) => Map<String, Object?>.from(r as Map))
            .toList();

  Future<void> stop() => _stopping ??= _stop();
  Future<void> _stop() async {
    _closed = true;
    _timer?.cancel();
    for (final waiter in _waiting.values) {
      waiter.completeError(StateError('Library closed.'));
    }
    _waiting.clear();
    _priority.clear();
    await embedder.dispose();
    await _starting;
    await _loop;
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}
