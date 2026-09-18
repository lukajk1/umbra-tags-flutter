import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

class LibraryTag {
  LibraryTag.fromMap(Map row)
    : id = row['id'] as String,
      name = row['name'] as String,
      parentId = row['parent_id'] as String?;
  final String id, name;
  final String? parentId;
}

/// Used only on the library worker. Schema v1 already includes these tables.
class TagRepository {
  TagRepository(this.db);
  final Database db;
  static const descendants = '''WITH RECURSIVE descendants(id) AS (
    SELECT id FROM tags WHERE id = ?
    UNION SELECT t.id FROM tags t JOIN descendants d ON t.parent_id = d.id
  )''';

  List<Map<String, Object?>> tags() => db
      .select(
        'SELECT id,name,parent_id FROM tags ORDER BY name COLLATE NOCASE,id',
      )
      .map((r) => Map<String, Object?>.from(r))
      .toList();

  String save({String? id, required String name, String? parentId}) {
    name = name.trim();
    if (name.isEmpty || name.length > 120) {
      throw StateError('Tag names must contain 1–120 characters.');
    }
    if (id != null) _requireTag(id);
    if (parentId != null) _requireTag(parentId);
    if (db.select(
      'SELECT id FROM tags WHERE name = ? COLLATE NOCASE AND id != ?',
      [name, id ?? ''],
    ).isNotEmpty) {
      throw StateError('A tag with that name already exists.');
    }
    if (id != null &&
        parentId != null &&
        db.select('$descendants SELECT id FROM descendants WHERE id = ?', [
          id,
          parentId,
        ]).isNotEmpty) {
      throw StateError(
        'A tag cannot be placed inside itself or its descendants.',
      );
    }
    final result = id ?? const Uuid().v4();
    if (id == null) {
      db.execute('INSERT INTO tags(id,name,parent_id) VALUES (?,?,?)', [
        result,
        name,
        parentId,
      ]);
    } else {
      db.execute('UPDATE tags SET name = ?,parent_id = ? WHERE id = ?', [
        name,
        parentId,
        id,
      ]);
    }
    return result;
  }

  void delete(String id) {
    _requireTag(id);
    final parent = db.select('SELECT parent_id FROM tags WHERE id = ?', [
      id,
    ]).first['parent_id'];
    _transaction(() {
      db.execute('UPDATE tags SET parent_id = ? WHERE parent_id = ?', [
        parent,
        id,
      ]);
      db.execute('DELETE FROM tags WHERE id = ?', [id]);
    });
  }

  void editAssignments(
    List<String> assetIds,
    List<String> add,
    List<String> remove,
  ) {
    if (add.toSet().intersection(remove.toSet()).isNotEmpty) {
      throw StateError('A tag cannot be both added and removed.');
    }
    for (final id in {...add, ...remove}) {
      _requireTag(id);
    }
    _transaction(() {
      for (final asset in assetIds.toSet()) {
        if (db.select('SELECT id FROM assets WHERE id = ?', [asset]).isEmpty) {
          throw StateError('An image no longer exists in this library.');
        }
        for (final tag in add.toSet()) {
          db.execute(
            'INSERT OR IGNORE INTO asset_tags(asset_id,tag_id) VALUES (?,?)',
            [asset, tag],
          );
        }
        for (final tag in remove.toSet()) {
          db.execute(
            'DELETE FROM asset_tags WHERE asset_id = ? AND tag_id = ?',
            [asset, tag],
          );
        }
      }
    });
  }

  List<Map<String, Object?>> assets(Map args) {
    final tagId = args['tagId'] as String?;
    final parameters = <Object?>[?tagId, args['archived'] == true ? 1 : 0];
    final query =
        '''${tagId == null ? '' : descendants}
      SELECT a.* FROM assets a WHERE a.archived = ?
      ${args['untagged'] == true ? 'AND NOT EXISTS (SELECT 1 FROM asset_tags at WHERE at.asset_id = a.id)' : ''}
      ${tagId == null ? '' : 'AND EXISTS (SELECT 1 FROM asset_tags at JOIN descendants d ON d.id = at.tag_id WHERE at.asset_id = a.id)'}
      ORDER BY a.imported_at DESC,a.id''';
    final result = db
        .select(query, parameters)
        .map((r) => <String, Object?>{...r, 'tag_ids': <String>[]})
        .toList();
    final byId = {for (final row in result) row['id']: row};
    for (final assignment in db.select(
      'SELECT asset_id,tag_id FROM asset_tags',
    )) {
      final row = byId[assignment['asset_id']];
      if (row != null) {
        (row['tag_ids'] as List<String>).add(assignment['tag_id'] as String);
      }
    }
    return result;
  }

  void _requireTag(String id) {
    if (db.select('SELECT id FROM tags WHERE id = ?', [id]).isEmpty) {
      throw StateError('This tag no longer exists.');
    }
  }

  void _transaction(void Function() operation) {
    db.execute('BEGIN IMMEDIATE');
    try {
      operation();
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}
