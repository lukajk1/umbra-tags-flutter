import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gallery_test/storage/library_store.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  late Directory folder;
  late LibraryStore store;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('umbra-tags-test-');
    final root = await Directory(p.join(folder.path, 'library')).create();
    store = await LibraryStore.create(root.path, 'Tags');
  });
  tearDown(() async {
    await store.close();
    await folder.delete(recursive: true);
  });
  Future<LibraryAsset> image(int width) async {
    final file = File(p.join(folder.path, '$width.png'));
    await file.writeAsBytes(img.encodePng(img.Image(width: width, height: 8)));
    return (await store.importImage(file.path)).asset;
  }

  test(
    'nested tag filters deduplicate assets and separate untagged/archive',
    () async {
      final a = await image(8), b = await image(9), c = await image(10);
      final parent = await store.saveTag(name: 'Nature');
      final child = await store.saveTag(name: 'Birds', parentId: parent);
      await store.editTags([a.id], add: [parent, child]);
      await store.editTags([b.id], add: [child]);
      expect((await store.assets(tagId: parent)).map((a) => a.id).toSet(), {
        a.id,
        b.id,
      });
      expect((await store.assets(untagged: true)).single.id, c.id);
      await store.archive([b.id], true);
      expect((await store.assets(tagId: parent)).single.id, a.id);
      expect(
        (await store.assets(archived: true, tagId: parent)).single.id,
        b.id,
      );
    },
  );

  test(
    'rename/reparent persists and cycles or duplicate names cannot corrupt hierarchy',
    () async {
      final first = await store.saveTag(name: ' First ');
      final second = await store.saveTag(name: 'Second', parentId: first);
      final third = await store.saveTag(name: 'Third', parentId: second);
      await expectLater(
        store.saveTag(id: first, name: 'First', parentId: third),
        throwsA(isA<LibraryException>()),
      );
      await expectLater(
        store.saveTag(name: 'first'),
        throwsA(isA<LibraryException>()),
      );
      await expectLater(
        store.saveTag(name: '  '),
        throwsA(isA<LibraryException>()),
      );
      await store.saveTag(id: third, name: 'Renamed', parentId: first);
      final root = store.root;
      await store.close();
      store = await LibraryStore.open(root);
      final tag = (await store.tags()).singleWhere((t) => t.id == third);
      expect(tag.name, 'Renamed');
      expect(tag.parentId, first);
      expect(
        (await store.tags()).singleWhere((t) => t.id == first).parentId,
        isNull,
      );
    },
  );

  test(
    'batch edits preserve unrelated tags and roll back on invalid assets',
    () async {
      final a = await image(8), b = await image(9);
      final keep = await store.saveTag(name: 'Keep');
      final shared = await store.saveTag(name: 'Shared');
      await store.editTags([a.id], add: [keep]);
      await store.editTags([a.id, b.id], add: [shared]);
      await expectLater(
        store.editTags([a.id, 'missing'], remove: [shared]),
        throwsA(isA<LibraryException>()),
      );
      var assets = await store.assets();
      expect(assets.singleWhere((v) => v.id == a.id).tagIds.toSet(), {
        keep,
        shared,
      });
      await store.editTags([a.id, b.id], remove: [shared]);
      assets = await store.assets();
      expect(assets.singleWhere((v) => v.id == a.id).tagIds, [keep]);
      expect(assets.singleWhere((v) => v.id == b.id).tagIds, isEmpty);
    },
  );

  test(
    'delete only removes that tag, promotes children and keeps originals',
    () async {
      final a = await image(8);
      final root = await store.saveTag(name: 'Root');
      final middle = await store.saveTag(name: 'Middle', parentId: root);
      final child = await store.saveTag(name: 'Child', parentId: middle);
      await store.editTags([a.id], add: [middle, child]);
      await store.deleteTag(middle);
      expect(
        (await store.tags()).singleWhere((t) => t.id == child).parentId,
        root,
      );
      expect((await store.assets()).single.tagIds, [child]);
      expect(File(store.absolutePath(a.relativePath)).existsSync(), isTrue);
      final location = store.root;
      await store.close();
      store = await LibraryStore.open(location);
      expect((await store.assets(tagId: root)).single.id, a.id);
    },
  );
}
