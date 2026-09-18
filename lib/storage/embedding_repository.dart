import 'dart:math' as math;
import 'dart:typed_data';
import 'package:sqlite3/sqlite3.dart';

/// Runs only in the library isolate, alongside all other catalog mutations.
class EmbeddingRepository {
  EmbeddingRepository(this.db);
  final Database db;

  Object? dispatch(Map args) {
    final key = args['key'] as String? ?? '';
    switch (args['op']) {
      case 'register':
        db.execute(
          '''INSERT OR IGNORE INTO embedding_models
          (model_key,model_id,revision,preprocessing,dimension) VALUES (?,?,?,?,?)''',
          [
            key,
            args['modelId'],
            args['revision'],
            args['preprocessing'],
            args['dimension'],
          ],
        );
        return null;
      case 'settings':
        if (args['enabled'] is bool) {
          db.execute(
            'INSERT OR REPLACE INTO similarity_settings(id,enabled) VALUES (1,?)',
            [args['enabled'] == true ? 1 : 0],
          );
        }
        return db
                .select('SELECT enabled FROM similarity_settings WHERE id=1')
                .first['enabled'] ==
            1;
      case 'state':
        final rows = db.select(
          '''SELECT COUNT(*) AS total,
          COALESCE(SUM(e.vector IS NOT NULL),0) AS ready,
          COALESCE(SUM(e.error IS NOT NULL),0) AS failed
          FROM assets a LEFT JOIN embeddings e ON e.asset_id=a.id
          AND e.model_key=? AND e.analyzed_sha256=a.sha256
          WHERE a.archived=0 AND a.missing=0''',
          [key],
        );
        return Map<String, Object?>.from(rows.first);
      case 'next':
        final rows = db.select(
          '''SELECT a.* FROM assets a
          LEFT JOIN embeddings e ON e.asset_id=a.id AND e.model_key=?
          AND e.analyzed_sha256=a.sha256
          WHERE a.archived=0 AND a.missing=0 AND e.asset_id IS NULL
          ORDER BY a.imported_at DESC,a.id LIMIT 1''',
          [key],
        );
        return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
      case 'has':
        return db
            .select(
              '''SELECT 1 FROM embeddings e JOIN assets a ON a.id=e.asset_id
          WHERE a.id=? AND e.model_key=? AND e.analyzed_sha256=a.sha256
          AND e.vector IS NOT NULL''',
              [args['assetId'], key],
            )
            .isNotEmpty;
      case 'save':
        final rows = db.select('SELECT sha256 FROM assets WHERE id=?', [
          args['assetId'],
        ]);
        // A deletion or content change during inference must not resurrect data.
        if (rows.isEmpty || rows.first['sha256'] != args['hash']) return false;
        final raw = args['vector'] as List?;
        Uint8List? bytes;
        if (raw != null) {
          if (raw.isEmpty || raw.length > 16384) {
            throw StateError('Invalid embedding dimension.');
          }
          final values = raw.map((v) => (v as num).toDouble()).toList();
          if (values.any((v) => !v.isFinite)) {
            throw StateError('Invalid embedding value.');
          }
          final norm = math.sqrt(values.fold<double>(0, (s, v) => s + v * v));
          if (norm <= 0) throw StateError('Empty embedding.');
          final data = ByteData(values.length * 4);
          for (var i = 0; i < values.length; i++) {
            data.setFloat32(i * 4, values[i] / norm, Endian.little);
          }
          bytes = data.buffer.asUint8List();
        }
        if (key.isEmpty || (bytes == null && args['error'] == null)) {
          throw StateError('Incomplete embedding result.');
        }
        db.execute(
          '''INSERT OR REPLACE INTO embeddings
          (asset_id,model_key,analyzed_sha256,dimension,vector,error,created_at)
          VALUES (?,?,?,?,?,?,?)''',
          [
            args['assetId'],
            key,
            args['hash'],
            raw?.length,
            bytes,
            bytes == null ? args['error'].toString() : null,
            DateTime.now().toUtc().millisecondsSinceEpoch,
          ],
        );
        return true;
      case 'retry':
        db.execute(
          'DELETE FROM embeddings WHERE model_key=? AND error IS NOT NULL',
          [key],
        );
        return null;
      case 'errors':
        return db
            .select(
              '''SELECT a.original_filename,e.error FROM embeddings e
          JOIN assets a ON a.id=e.asset_id WHERE e.model_key=? AND e.error IS NOT NULL
          AND e.analyzed_sha256=a.sha256 ORDER BY e.created_at DESC LIMIT 100''',
              [key],
            )
            .map((r) => Map<String, Object?>.from(r))
            .toList();
      case 'search':
        final source = db.select(
          '''SELECT e.vector,e.dimension FROM embeddings e
          JOIN assets a ON a.id=e.asset_id WHERE a.id=? AND e.model_key=?
          AND e.analyzed_sha256=a.sha256 AND e.vector IS NOT NULL''',
          [args['assetId'], key],
        );
        if (source.isEmpty) return <Map<String, Object?>>[];
        final dimension = source.first['dimension'] as int;
        final query = ByteData.sublistView(source.first['vector'] as Uint8List);
        final result = <Map<String, Object?>>[];
        final statement = db.prepare(
          '''SELECT a.*,e.vector FROM assets a JOIN embeddings e ON e.asset_id=a.id
          WHERE e.model_key=? AND e.analyzed_sha256=a.sha256 AND e.dimension=?
          AND e.vector IS NOT NULL AND a.id!=? AND a.archived=0 AND a.missing=0''',
        );
        try {
          final cursor = statement.selectCursor([
            key,
            dimension,
            args['assetId'],
          ]);
          while (cursor.moveNext()) {
            final row = cursor.current;
            final vector = ByteData.sublistView(row['vector'] as Uint8List);
            var score = 0.0;
            for (var i = 0; i < dimension; i++) {
              score +=
                  query.getFloat32(i * 4, Endian.little) *
                  vector.getFloat32(i * 4, Endian.little);
            }
            if (result.length < 50 ||
                score > (result.last['score'] as double)) {
              final item = Map<String, Object?>.from(row)..remove('vector');
              item['score'] = score.clamp(-1.0, 1.0);
              result.add(item);
              result.sort(
                (a, b) =>
                    (b['score'] as double).compareTo(a['score'] as double),
              );
              if (result.length > 50) result.removeLast();
            }
          }
        } finally {
          statement.close();
        }
        return result;
    }
    throw StateError('Unknown embedding operation.');
  }
}
