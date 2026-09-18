import 'classifier.dart';
import '../storage/library_store.dart';

class EmbeddingModel {
  EmbeddingModel(Map<String, dynamic> data)
    : key = data['key'] as String,
      name = data['modelId'] as String,
      revision = data['revision'] as String,
      preprocessing = data['preprocessing'] as String,
      dimension = data['dimension'] as int;
  final String key, name, revision, preprocessing;
  final int dimension;
}

/// Implement this interface to replace Python, the model, or the runtime.
/// Embedders never write to a library or assign tags.
abstract interface class ImageEmbedder {
  Future<EmbeddingModel> info();
  Future<void> load();
  Future<List<double>> embed(LibraryAsset asset, String absolutePath);
  Future<void> dispose();
}

class PythonImageEmbedder implements ImageEmbedder {
  PythonImageEmbedder({String? home, String? python})
    : _transport = PythonImageClassifier(home: home, python: python);
  final PythonImageClassifier _transport;
  EmbeddingModel? _model;

  @override
  Future<EmbeddingModel> info() async =>
      _model ??= EmbeddingModel(await _transport.requestEmbedding('info'));
  @override
  Future<void> load() async {
    final expected = await info();
    final actual = await _transport.requestEmbedding('load');
    if (actual['key'] != expected.key) {
      throw StateError('Embedding model changed; restart indexing.');
    }
  }

  @override
  Future<List<double>> embed(LibraryAsset asset, String absolutePath) async {
    final expected = await info();
    final result = await _transport.requestEmbedding('compute', {
      'assetId': asset.id,
      'contentHash': asset.contentHash,
      'imagePath': absolutePath,
    });
    final vector = (result['vector'] as List)
        .map((v) => (v as num).toDouble())
        .toList();
    if (result['key'] != expected.key ||
        result['assetId'] != asset.id ||
        result['contentHash'] != asset.contentHash ||
        vector.length != expected.dimension) {
      throw StateError('Embedding does not match this image or model.');
    }
    return vector;
  }

  @override
  Future<void> dispose() => _transport.dispose();
}
