import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'schema.dart';

class LibraryException implements Exception {
  LibraryException(this.message);
  final String message;
  @override
  String toString() => message;
}

class LibraryAsset {
  LibraryAsset.fromMap(Map<String, Object?> row)
    : id = row['id'] as String,
      relativePath = row['relative_path'] as String,
      originalFilename = row['original_filename'] as String,
      width = row['width'] as int,
      height = row['height'] as int,
      contentHash = row['sha256'] as String,
      missing = row['missing'] == 1,
      archived = row['archived'] == 1;

  final String id, relativePath, originalFilename, contentHash;
  final int width, height;
  final bool missing, archived;
  String get thumbnailRelativePath =>
      'cache/thumbnails/$id-$contentHash-v2.jpg';
}

class ImportResult {
  ImportResult(this.asset, this.duplicate);
  final LibraryAsset asset;
  final bool duplicate;
}

/// The only owner of library writes. SQLite and codecs live in a worker isolate.
/// Each request is processed serially, including file operations and recovery.
class LibraryStore {
  LibraryStore._(this.root, this.id, this.name, this._worker, this._isolate);
  final String root, id, name;
  final SendPort _worker;
  final Isolate _isolate;
  bool _closed = false;
  Future<void>? _closing;
  static final Set<String> _openRoots = {};
  static const supportedExtensions = [
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
  ];

  static Future<LibraryStore> create(String root, String name) =>
      _start(root, name: name);
  static Future<LibraryStore> open(String root) => _start(root);

  static Future<LibraryStore> _start(String root, {String? name}) async {
    final canonical = await Directory(root).resolveSymbolicLinks();
    final key = Platform.isWindows ? canonical.toLowerCase() : canonical;
    if (!_openRoots.add(key)) {
      throw LibraryException('This library is already open. Close it first.');
    }
    final ready = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(_libraryWorker, [
        ready.sendPort,
        canonical,
        name,
      ]);
      final response = await ready.first as Map;
      if (response['error'] != null) {
        throw LibraryException(response['error'] as String);
      }
      return LibraryStore._(
        canonical,
        response['id'] as String,
        response['name'] as String,
        response['port'] as SendPort,
        isolate,
      );
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
      _openRoots.remove(key);
      rethrow;
    } finally {
      ready.close();
    }
  }

  Future<Object?> _call(String method, [Object? arguments]) async {
    if (_closed || (_closing != null && method != 'close')) {
      throw LibraryException('Library is closed.');
    }
    final reply = ReceivePort();
    try {
      _worker.send([reply.sendPort, method, arguments]);
      final response = await reply.first as Map;
      if (response['error'] != null) {
        throw LibraryException(response['error'] as String);
      }
      return response['value'];
    } finally {
      reply.close();
    }
  }

  String absolutePath(String relative) => _resolve(root, relative);
  Future<List<LibraryAsset>> assets({bool archived = false}) async =>
      (await _call('assets', archived) as List)
          .map(
            (row) =>
                LibraryAsset.fromMap(Map<String, Object?>.from(row as Map)),
          )
          .toList();

  Future<ImportResult> importImage(String sourcePath) async {
    final result = await _call('import', sourcePath) as Map;
    return ImportResult(
      LibraryAsset.fromMap(Map<String, Object?>.from(result['asset'] as Map)),
      result['duplicate'] as bool,
    );
  }

  Future<String?> thumbnail(LibraryAsset asset) async =>
      await _call('thumbnail', asset.id) as String?;
  Future<void> refresh() async {
    await _call('refresh');
  }

  Future<void> archive(List<String> ids, bool archived) async {
    await _call('archive', {'ids': ids, 'archived': archived});
  }

  Future<String> backup() async => await _call('backup') as String;

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    try {
      await _call('close');
    } finally {
      _closed = true;
      _openRoots.remove(Platform.isWindows ? root.toLowerCase() : root);
      _isolate.kill(priority: Isolate.immediate);
    }
  }
}

String _resolve(String root, String relative) {
  if (relative.isEmpty ||
      relative.contains('\\') ||
      relative.contains(':') ||
      p.posix.isAbsolute(relative) ||
      relative.split('/').any((s) => s == '..' || s.isEmpty)) {
    throw LibraryException('Invalid library-relative path: $relative');
  }
  final result = p.normalize(p.joinAll([root, ...relative.split('/')]));
  if (!p.isWithin(root, result)) {
    throw LibraryException('Path leaves the library.');
  }
  // Reject symlink components, including broken links, before reading or writing.
  var current = root;
  for (final segment in relative.split('/')) {
    current = p.join(current, segment);
    if (FileSystemEntity.typeSync(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw LibraryException(
        'Library files cannot use symbolic links: $relative',
      );
    }
  }
  return result;
}

void _libraryWorker(List<Object?> init) {
  final ready = init[0] as SendPort;
  _LibraryEngine? engine;
  try {
    engine = _LibraryEngine(init[1] as String, init[2] as String?);
    final requests = ReceivePort();
    ready.send({
      'port': requests.sendPort,
      'id': engine.id,
      'name': engine.name,
    });
    final active = engine;
    requests.listen((message) {
      final request = message as List;
      final reply = request[0] as SendPort;
      try {
        final value = active.dispatch(request[1] as String, request[2]);
        reply.send({'value': value});
      } catch (error) {
        reply.send({'error': error.toString()});
      }
      if (request[1] == 'close') requests.close();
    });
  } catch (error) {
    engine?.close();
    ready.send({'error': error.toString()});
  }
}

class _LibraryEngine {
  _LibraryEngine(this.root, String? newName) {
    try {
      if (newName != null) {
        if (newName.trim().isEmpty) {
          throw LibraryException('Enter a library name.');
        }
        if (Directory(root).listSync().isNotEmpty) {
          throw LibraryException('Choose an empty folder for a new library.');
        }
      }
      final manifestFile = File(path('library.json'));
      if (newName == null && !manifestFile.existsSync()) {
        throw LibraryException(
          'This folder does not contain an Umbra library.',
        );
      }
      // Keep the lock file in place. Unlinking it could let writers lock different files.
      _lock = File(path('.umbra.lock')).openSync(mode: FileMode.append);
      try {
        _lock!.lockSync(FileLock.exclusive);
      } catch (_) {
        throw LibraryException(
          'This library is in use by another app. Close it there first.',
        );
      }
      if (newName != null) {
        id = const Uuid().v4();
        name = newName.trim();
        _db = sqlite3.open(path('catalog.sqlite'));
        _db!.execute('PRAGMA foreign_keys = ON');
        _db!.execute('BEGIN IMMEDIATE');
        try {
          _db!.execute(createSchema);
          _db!.execute('INSERT INTO library VALUES (?, ?, ?)', [id, name, now]);
          _db!.execute('COMMIT');
        } catch (_) {
          _db!.execute('ROLLBACK');
          rethrow;
        }
        _ensureDirectories();
        final temp = File(path('library.json.tmp'));
        temp.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'format': libraryFormat,
            'formatVersion': libraryFormatVersion,
            'libraryId': id,
          }),
          flush: true,
        );
        temp.renameSync(manifestFile.path);
      } else {
        final manifest = jsonDecode(manifestFile.readAsStringSync());
        if (manifest is! Map ||
            manifest['format'] != libraryFormat ||
            manifest['formatVersion'] != libraryFormatVersion ||
            manifest['libraryId'] is! String) {
          throw LibraryException('Unrecognized or unsupported library format.');
        }
        id = manifest['libraryId'] as String;
        if (!File(path('catalog.sqlite')).existsSync()) {
          throw LibraryException(
            'Library catalog is missing. Restore it from a backup.',
          );
        }
        _db = sqlite3.open(path('catalog.sqlite'), mode: OpenMode.readWrite);
        final version = _db!.select('PRAGMA user_version').first.values.first;
        if (version != librarySchemaVersion) {
          throw LibraryException(
            'Unsupported catalog schema $version. No migration was performed.',
          );
        }
        final rows = _db!.select('SELECT * FROM library');
        if (rows.length != 1 || rows.first['id'] != id) {
          throw LibraryException('Library manifest and catalog do not match.');
        }
        name = rows.first['name'] as String;
        _ensureDirectories();
      }
      db.execute('PRAGMA foreign_keys = ON');
      db.execute('PRAGMA journal_mode = DELETE');
      db.execute('PRAGMA synchronous = FULL');
      _recover();
    } catch (_) {
      close();
      rethrow;
    }
  }

  final String root;
  late final String id, name;
  Database? _db;
  RandomAccessFile? _lock;
  Database get db => _db!;
  int get now => DateTime.now().toUtc().millisecondsSinceEpoch;
  String path(String relative) => _resolve(root, relative);

  void _ensureDirectories() {
    for (final dir in [
      'media',
      'cache/thumbnails',
      'cache/previews',
      'staging',
      'backups',
    ]) {
      Directory(path(dir)).createSync(recursive: true);
    }
  }

  Object? dispatch(String method, Object? args) {
    switch (method) {
      case 'assets':
        return db
            .select(
              'SELECT * FROM assets WHERE archived = ? ORDER BY imported_at DESC, id',
              [args == true ? 1 : 0],
            )
            .map((r) => Map<String, Object?>.from(r))
            .toList();
      case 'import':
        return _import(args as String);
      case 'thumbnail':
        return _thumbnail(args as String);
      case 'refresh':
        _refresh();
        return null;
      case 'archive':
        final values = args as Map;
        db.execute('BEGIN IMMEDIATE');
        try {
          for (final assetId in values['ids'] as List) {
            db.execute('UPDATE assets SET archived = ? WHERE id = ?', [
              values['archived'] == true ? 1 : 0,
              assetId,
            ]);
          }
          db.execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
        return null;
      case 'backup':
        final relative = 'backups/catalog-$now-${const Uuid().v4()}.sqlite';
        db.execute('VACUUM INTO ?', [path(relative)]);
        return path(relative);
      case 'close':
        close();
        return null;
      default:
        throw LibraryException('Unknown library operation.');
    }
  }

  Map<String, Object?> _import(String source) {
    final file = File(source);
    final extension = p.extension(source).toLowerCase().replaceFirst('.', '');
    if (!LibraryStore.supportedExtensions.contains(extension)) {
      throw LibraryException('Unsupported image type: ${p.basename(source)}');
    }
    final assetId = const Uuid().v4();
    final stage = File(path('staging/$assetId.part'));
    final journal = File(path('staging/$assetId.json'));
    var journalWritten = false;
    try {
      file.copySync(stage.path);
      final bytes = stage.readAsBytesSync();
      final hash = sha256.convert(bytes).toString();
      final existing = db.select('SELECT * FROM assets WHERE sha256 = ?', [
        hash,
      ]);
      if (existing.isNotEmpty) {
        final row = existing.first;
        final destination = File(path(row['relative_path'] as String));
        if (!destination.existsSync()) {
          destination.parent.createSync(recursive: true);
          stage.renameSync(destination.path);
        }
        db.execute('UPDATE assets SET missing = 0 WHERE id = ?', [row['id']]);
        return {
          'duplicate': true,
          'asset': Map<String, Object?>.from(
            db.select('SELECT * FROM assets WHERE id = ?', [row['id']]).first,
          ),
        };
      }
      final decoded = img.decodeImage(bytes, frame: 0);
      if (decoded == null) {
        throw LibraryException('Could not decode ${p.basename(source)}.');
      }
      final oriented = img.bakeOrientation(decoded);
      final ext = img.findFormatForData(bytes).name;
      if (!LibraryStore.supportedExtensions.contains(ext)) {
        throw LibraryException('Unsupported encoded image format: $ext');
      }
      final relative = 'media/${assetId.substring(0, 2)}/$assetId.$ext';
      final record = <String, Object?>{
        'id': assetId,
        'relative_path': relative,
        'original_filename': p.basename(source),
        'media_type': 'image/${ext == 'jpg' ? 'jpeg' : ext}',
        'width': oriented.width,
        'height': oriented.height,
        'byte_size': bytes.length,
        'imported_at': now,
        'source_modified_at': file
            .lastModifiedSync()
            .toUtc()
            .millisecondsSinceEpoch,
        'sha256': hash,
      };
      // A flushed journal precedes the media rename; recovery can finish the SQL insert.
      final journalTemp = File('${journal.path}.tmp');
      journalTemp.writeAsStringSync(jsonEncode(record), flush: true);
      journalTemp.renameSync(journal.path);
      journalWritten = true;
      final destination = File(path(relative));
      destination.parent.createSync(recursive: true);
      stage.renameSync(destination.path);
      _insertAsset(record);
      journal.deleteSync();
      journalWritten = false;
      return {
        'duplicate': false,
        'asset': Map<String, Object?>.from(
          db.select('SELECT * FROM assets WHERE id = ?', [assetId]).first,
        ),
      };
    } finally {
      // Preserve staged bytes when a journal exists so an interrupted import is recoverable.
      if (!journalWritten && stage.existsSync()) stage.deleteSync();
    }
  }

  void _insertAsset(Map<String, Object?> record) {
    db.execute(
      '''INSERT INTO assets
      (id,relative_path,original_filename,media_type,width,height,byte_size,
       imported_at,source_modified_at,sha256) VALUES (?,?,?,?,?,?,?,?,?,?)''',
      [
        'id',
        'relative_path',
        'original_filename',
        'media_type',
        'width',
        'height',
        'byte_size',
        'imported_at',
        'source_modified_at',
        'sha256',
      ].map((k) => record[k]).toList(),
    );
  }

  String? _thumbnail(String assetId) {
    final rows = db.select('SELECT * FROM assets WHERE id = ?', [assetId]);
    if (rows.isEmpty) return null;
    final asset = LibraryAsset.fromMap(Map<String, Object?>.from(rows.first));
    final source = File(path(asset.relativePath));
    if (!source.existsSync()) {
      db.execute('UPDATE assets SET missing = 1 WHERE id = ?', [assetId]);
      return null;
    }
    final target = File(path(asset.thumbnailRelativePath));
    if (target.existsSync()) return target.path;
    final decoded = img.decodeImage(source.readAsBytesSync(), frame: 0);
    if (decoded == null) return null;
    final oriented = img.bakeOrientation(decoded);
    final resized = oriented.width <= 1280 && oriented.height <= 1280
        ? oriented
        : img.copyResize(
            oriented,
            width: oriented.width >= oriented.height ? 1280 : null,
            height: oriented.height > oriented.width ? 1280 : null,
            interpolation: img.Interpolation.average,
          );
    target.parent.createSync(recursive: true);
    final temp = File('${target.path}.tmp');
    temp.writeAsBytesSync(img.encodeJpg(resized, quality: 92), flush: true);
    temp.renameSync(target.path);
    return target.path;
  }

  void _recover() {
    for (final entry in Directory(
      path('staging'),
    ).listSync(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      final record = Map<String, Object?>.from(
        jsonDecode(entry.readAsStringSync()) as Map,
      );
      final assetId = record['id'] as String;
      if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(assetId) ||
          p.basename(entry.path) != '$assetId.json' ||
          !(record['relative_path'] as String).startsWith('media/')) {
        throw LibraryException(
          'Invalid import journal. Recovery stopped without deleting files.',
        );
      }
      final destination = File(path(record['relative_path'] as String));
      final stage = File(path('staging/$assetId.part'));
      final existing = db.select(
        'SELECT sha256,relative_path FROM assets WHERE id = ?',
        [assetId],
      );
      if (existing.isNotEmpty) {
        if (existing.first['sha256'] != record['sha256'] ||
            existing.first['relative_path'] != record['relative_path']) {
          throw LibraryException(
            'Import journal conflicts with an existing asset.',
          );
        }
        entry.deleteSync();
        continue;
      }
      final candidate = destination.existsSync() ? destination : stage;
      if (!candidate.existsSync()) {
        throw LibraryException(
          'Incomplete import $assetId has no media. Files were preserved.',
        );
      }
      if (sha256.convert(candidate.readAsBytesSync()).toString() !=
          record['sha256']) {
        throw LibraryException(
          'Incomplete import $assetId failed its content check.',
        );
      }
      if (!destination.existsSync()) {
        destination.parent.createSync(recursive: true);
        stage.renameSync(destination.path);
      }
      _insertAsset(record);
      entry.deleteSync();
    }
    db.execute(
      "UPDATE jobs SET status = 'interrupted', updated_at = ? WHERE status = 'running'",
      [now],
    );
    _refresh();
  }

  void _refresh() {
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final row in db.select('SELECT id,relative_path FROM assets')) {
        final exists = File(path(row['relative_path'] as String)).existsSync();
        db.execute('UPDATE assets SET missing = ? WHERE id = ?', [
          exists ? 0 : 1,
          row['id'],
        ]);
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void close() {
    _db?.close();
    _db = null;
    _lock?.closeSync();
    _lock = null;
  }
}
