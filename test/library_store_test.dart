import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gallery_test/storage/library_store.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory sandbox;
  final opened = <LibraryStore>[];
  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('umbra-storage-test-');
  });
  tearDown(() async {
    for (final store in opened.reversed) {
      await store.close();
    }
    opened.clear();
    await sandbox.delete(recursive: true);
  });
  Future<LibraryStore> create([String folder = 'library']) async {
    final root = await Directory(p.join(sandbox.path, folder)).create();
    final store = await LibraryStore.create(root.path, 'Test Library');
    opened.add(store);
    return store;
  }

  Future<File> picture(String filename, {int width = 30}) async {
    final image = img.Image(width: width, height: 20);
    img.fill(image, color: img.ColorRgb8(80, 100, 120));
    return File(
      p.join(sandbox.path, filename),
    ).writeAsBytes(img.encodePng(image));
  }

  test(
    'imports immutable originals, skips exact duplicates and persists archive state',
    () async {
      final store = await create();
      final source = await picture('photo.png');
      final bytes = await source.readAsBytes();
      final result = await store.importImage(source.path);
      expect(result.duplicate, isFalse);
      expect(result.asset.originalFilename, 'photo.png');
      expect(result.asset.relativePath, startsWith('media/'));
      expect(result.asset.relativePath, isNot(contains(sandbox.path)));
      expect(
        await File(store.absolutePath(result.asset.relativePath)).readAsBytes(),
        bytes,
      );
      expect(await source.readAsBytes(), bytes);
      final duplicate = await store.importImage(source.path);
      expect(duplicate.duplicate, isTrue);
      expect(duplicate.asset.id, result.asset.id);
      expect(await store.assets(), hasLength(1));
      await store.archive([result.asset.id], true);
      final root = store.root;
      await store.close();
      final reopened = await LibraryStore.open(root);
      opened.add(reopened);
      expect(await reopened.assets(), isEmpty);
      expect(
        (await reopened.assets(archived: true)).single.id,
        result.asset.id,
      );
    },
  );

  test(
    'moving the folder preserves identity, originals and regenerated caches',
    () async {
      final store = await create();
      final result = await store.importImage((await picture('image.png')).path);
      final thumb = await store.thumbnail(result.asset);
      expect(File(thumb!).existsSync(), isTrue);
      final id = store.id;
      final root = store.root;
      await store.close();
      await Directory(p.join(root, 'cache')).delete(recursive: true);
      final moved = await Directory(
        root,
      ).rename(p.join(sandbox.path, 'renamed library'));
      final reopened = await LibraryStore.open(moved.path);
      opened.add(reopened);
      expect(reopened.id, id);
      final asset = (await reopened.assets()).single;
      expect(
        File(reopened.absolutePath(asset.relativePath)).existsSync(),
        isTrue,
      );
      expect(File((await reopened.thumbnail(asset))!).existsSync(), isTrue);
    },
  );

  test(
    'missing files retain metadata and importing identical content repairs them',
    () async {
      final store = await create();
      final source = await picture('missing.png');
      final asset = (await store.importImage(source.path)).asset;
      await File(store.absolutePath(asset.relativePath)).delete();
      await store.refresh();
      expect((await store.assets()).single.missing, isTrue);
      final repair = await store.importImage(source.path);
      expect(repair.asset.id, asset.id);
      expect((await store.assets()).single.missing, isFalse);
    },
  );

  test(
    'rejects occupied folders, duplicate opens, future schemas and unsafe paths',
    () async {
      final store = await create();
      await expectLater(
        LibraryStore.open(store.root),
        throwsA(isA<LibraryException>()),
      );
      expect(
        () => store.absolutePath('../outside'),
        throwsA(isA<LibraryException>()),
      );
      expect(
        () => store.absolutePath('C:/outside'),
        throwsA(isA<LibraryException>()),
      );
      expect(
        () => store.absolutePath('media/../../outside'),
        throwsA(isA<LibraryException>()),
      );
      final root = store.root;
      await store.close();
      await expectLater(
        LibraryStore.create(root, 'Other'),
        throwsA(isA<LibraryException>()),
      );
      final db = sqlite3.open(p.join(root, 'catalog.sqlite'));
      db.execute('PRAGMA user_version = 999');
      db.close();
      await expectLater(
        LibraryStore.open(root),
        throwsA(isA<LibraryException>()),
      );
    },
  );

  test(
    'failed image imports leave no catalog entries or copied originals',
    () async {
      final store = await create();
      final invalid = await File(
        p.join(sandbox.path, 'broken.png'),
      ).writeAsString('not an image');
      await expectLater(
        store.importImage(invalid.path),
        throwsA(isA<LibraryException>()),
      );
      expect(await store.assets(), isEmpty);
      expect(Directory(p.join(store.root, 'staging')).listSync(), isEmpty);
      expect(await invalid.readAsString(), 'not an image');
    },
  );

  test('backup is a consistent independently readable catalog', () async {
    final store = await create();
    await store.importImage((await picture('backup.png')).path);
    final backup = await store.backup();
    final db = sqlite3.open(backup, mode: OpenMode.readOnly);
    expect(db.select('SELECT * FROM assets'), hasLength(1));
    expect(db.select('PRAGMA integrity_check').first.values.first, 'ok');
    db.close();
  });

  test(
    'uses actual media format, and concurrent close calls release the lock once',
    () async {
      final store = await create();
      final source = await picture('misnamed.jpg');
      final asset = (await store.importImage(source.path)).asset;
      expect(asset.relativePath, endsWith('.png'));
      expect(asset.originalFilename, 'misnamed.jpg');
      final root = store.root;
      await Future.wait([store.close(), store.close()]);
      final reopened = await LibraryStore.open(root);
      opened.add(reopened);
      expect(await reopened.assets(), hasLength(1));
    },
  );

  test(
    'journal recovers a crash after media rename but before SQL commit',
    () async {
      final store = await create();
      final root = store.root;
      await store.close();
      final source = await picture('recovered.png');
      final bytes = await source.readAsBytes();
      const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const relative = 'media/aa/$id.png';
      final destination = File(p.joinAll([root, ...relative.split('/')]));
      await destination.parent.create(recursive: true);
      await source.copy(destination.path);
      final record = {
        'id': id,
        'relative_path': relative,
        'original_filename': 'recovered.png',
        'media_type': 'image/png',
        'width': 30,
        'height': 20,
        'byte_size': bytes.length,
        'imported_at': 1,
        'source_modified_at': 1,
        'sha256': sha256.convert(bytes).toString(),
      };
      await File(
        p.join(root, 'staging', '$id.json'),
      ).writeAsString(jsonEncode(record));
      final reopened = await LibraryStore.open(root);
      opened.add(reopened);
      expect((await reopened.assets()).single.id, id);
      expect(Directory(p.join(root, 'staging')).listSync(), isEmpty);
      await reopened.close();
      final again = await LibraryStore.open(root);
      opened.add(again);
      expect(await again.assets(), hasLength(1));
    },
  );
}
