import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

/// All code-driven tag creation/assignment and prediction writes stay on the
/// library worker. No model or Python dependency is needed by this API.
class ClassificationRepository {
  ClassificationRepository(this.db);
  final Database db;

  /// Commit manual batch edits and explicitly accepted per-image suggestions
  /// together. Suggestions never apply themselves or affect other images.
  void applyReviewedTags(Map args) {
    final assets = (args['assets'] as List).cast<Map>();
    final accepted = args['accepted'] as Map;
    final add = (args['add'] as List).cast<String>().toSet();
    final remove = (args['remove'] as List).cast<String>().toSet();
    final ids = assets.map((a) => a['id'] as String).toSet();
    if (accepted.keys.any((id) => !ids.contains(id))) {
      throw StateError('Suggestion image is not in this selection.');
    }
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final tag in {...add, ...remove}) {
        if (db.select('SELECT id FROM tags WHERE id=?', [tag]).isEmpty) {
          throw StateError('A selected tag no longer exists.');
        }
      }
      for (final asset in assets) {
        final rows = db.select('SELECT sha256 FROM assets WHERE id=?', [
          asset['id'],
        ]);
        if (rows.isEmpty || rows.first['sha256'] != asset['hash']) {
          throw StateError(
            'An image changed or was deleted; review tags again.',
          );
        }
        _assign([
          asset['id'] as String,
        ], ((accepted[asset['id']] as List?) ?? []).cast<String>());
        for (final tag in add) {
          db.execute(
            'INSERT OR IGNORE INTO asset_tags(asset_id,tag_id) VALUES (?,?)',
            [asset['id'], tag],
          );
        }
        // An explicit removal in the manual tab wins over an accepted suggestion.
        for (final tag in remove) {
          db.execute('DELETE FROM asset_tags WHERE asset_id=? AND tag_id=?', [
            asset['id'],
            tag,
          ]);
        }
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  List<String> tagAssets(List<String> assetIds, List<String> names) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final tags = _assign(assetIds, names);
      db.execute('COMMIT');
      return tags;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  List<String> _assign(List<String> assetIds, List<String> names) {
    for (final id in assetIds.toSet()) {
      if (db.select('SELECT id FROM assets WHERE id = ?', [id]).isEmpty) {
        throw StateError('Image no longer exists.');
      }
    }
    if (assetIds.isEmpty) return [];
    final ids = <String>[];
    for (final name in names.map((value) => value.trim()).toSet()) {
      if (name.isEmpty || name.length > 120) {
        throw StateError('Tag names must contain 1–120 characters.');
      }
      final existing = db.select(
        'SELECT id FROM tags WHERE name = ? COLLATE NOCASE',
        [name],
      );
      final tagId = existing.isEmpty
          ? const Uuid().v4()
          : existing.single['id'] as String;
      if (existing.isEmpty) {
        db.execute('INSERT INTO tags(id,name) VALUES (?,?)', [tagId, name]);
      }
      for (final id in assetIds.toSet()) {
        db.execute(
          'INSERT OR IGNORE INTO asset_tags(asset_id,tag_id) VALUES (?,?)',
          [id, tagId],
        );
      }
      ids.add(tagId);
    }
    return ids.toSet().toList();
  }

  List<String> apply(Map args) {
    final assetId = args['assetId'] as String;
    final hash = args['contentHash'] as String;
    final model = args['modelId'] as String;
    final version = args['modelVersion'] as String;
    final threshold = (args['threshold'] as num).toDouble();
    if (!threshold.isFinite || threshold < 0 || threshold > 1) {
      throw StateError('Invalid confidence threshold.');
    }
    if (model.isEmpty || version.isEmpty) {
      throw StateError('Missing model identity.');
    }
    final scores = (args['scores'] as List).map((row) {
      final label = (row['label'] as String).trim();
      final confidence = (row['confidence'] as num).toDouble();
      if (label.isEmpty ||
          label.length > 120 ||
          !confidence.isFinite ||
          confidence < 0 ||
          confidence > 1) {
        throw StateError('Invalid classifier score.');
      }
      return (label: label, confidence: confidence);
    }).toList()..sort((a, b) => b.confidence.compareTo(a.confidence));
    if (scores.isEmpty ||
        scores.map((row) => row.label).toSet().length != scores.length) {
      throw StateError('Classifier returned empty or duplicate labels.');
    }
    db.execute('BEGIN IMMEDIATE');
    try {
      final assets = db.select('SELECT sha256 FROM assets WHERE id = ?', [
        assetId,
      ]);
      if (assets.isEmpty || assets.single['sha256'] != hash) {
        throw StateError(
          'Image changed or was deleted; stale prediction rejected.',
        );
      }
      db.execute(
        'DELETE FROM predictions WHERE asset_id = ? AND model_id = ? AND model_version = ? AND analyzed_sha256 = ?',
        [assetId, model, version, hash],
      );
      for (final score in scores) {
        db.execute(
          'INSERT INTO predictions(id,asset_id,model_id,model_version,label,confidence,analyzed_sha256,created_at) VALUES (?,?,?,?,?,?,?,?)',
          [
            const Uuid().v4(),
            assetId,
            model,
            version,
            score.label,
            score.confidence,
            hash,
            DateTime.now().toUtc().millisecondsSinceEpoch,
          ],
        );
      }
      final labels =
          args['assignTags'] == true && scores.first.confidence >= threshold
          ? [scores.first.label]
          : <String>[];
      _assign([assetId], labels);
      db.execute('COMMIT');
      return labels;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}
