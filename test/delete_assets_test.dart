import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gallery_test/storage/library_store.dart';
import 'package:image/image.dart' as img;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory temp;
  late LibraryStore store;
  late File source;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('umbra-delete-');
    final root = await Directory('${temp.path}/library').create();
    store = await LibraryStore.create(root.path, 'Delete test');
    source = await File(
      '${temp.path}/source.png',
    ).writeAsBytes(img.encodePng(img.Image(width: 20, height: 10)));
  });
  tearDown(() async {
    await store.close();
    await temp.delete(recursive: true);
  });
  test(
    'deletes original, thumbnail and assignments but keeps tags and external source',
    () async {
      final asset = (await store.importImage(source.path)).asset;
      final tag = await store.saveTag(name: 'Keep tag');
      await store.editTags([asset.id], add: [tag]);
      final thumbnail = await store.thumbnail(asset);
      await store.deleteAssets([asset.id, asset.id, 'not-present']);
      expect(await store.assets(), isEmpty);
      expect(
        await File(store.absolutePath(asset.relativePath)).exists(),
        false,
      );
      expect(await File(thumbnail!).exists(), false);
      expect(await source.exists(), true);
      expect((await store.tags()).single.id, tag);
      final root = store.root;
      await store.close();
      final db = sqlite3.open('$root/catalog.sqlite');
      expect(db.select('SELECT * FROM asset_tags'), isEmpty);
      db.close();
      store = await LibraryStore.open(root);
      expect(await store.assets(), isEmpty);
      expect((await store.importImage(source.path)).duplicate, false);
    },
  );
  test('deletes missing and archived images', () async {
    final asset = (await store.importImage(source.path)).asset;
    await store.archive([asset.id], true);
    await File(store.absolutePath(asset.relativePath)).delete();
    await store.deleteAssets([asset.id]);
    expect(await store.assets(archived: true), isEmpty);
  });
  test('reopening completes an interrupted deletion', () async {
    final asset = (await store.importImage(source.path)).asset;
    final root = store.root;
    await store.close();
    await File('$root/staging/delete-test.json').writeAsString(
      jsonEncode({
        'operation': 'delete',
        'assets': [
          {
            'id': asset.id,
            'relative_path': asset.relativePath,
            'sha256': asset.contentHash,
          },
        ],
      }),
    );
    await File('$root/${asset.relativePath}').delete();
    store = await LibraryStore.open(root);
    expect(await store.assets(), isEmpty);
    expect(await File('$root/staging/delete-test.json').exists(), false);
  });
}
