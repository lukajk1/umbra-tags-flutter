import 'dart:io';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gallery_test/main.dart';
import 'package:flutter_gallery_test/storage/library_store.dart';
import 'package:image/image.dart' as img;

class _Picker extends FileSelectorPlatform {
  _Picker(this.path);
  final String path;
  @override
  Future<String?> getDirectoryPathWithOptions(
    FileDialogOptions options,
  ) async => path;
}

Future<void> until(WidgetTester tester, bool Function() predicate) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
    if (predicate()) return;
  }
  fail(
    'Deletion UI did not reach expected state: ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join(' | ')}; ${tester.widgetList<SelectableText>(find.byType(SelectableText)).map((text) => text.data).join(' | ')}',
  );
}

void main() {
  testWidgets(
    'context target, Delete key, text focus, batch cancel and batch confirm',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('umbra-delete-ui-');
      final root = Directory('${temp.path}/library')..createSync();
      final previous = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = _Picker(root.path);
      addTearDown(() {
        FileSelectorPlatform.instance = previous;
        temp.deleteSync(recursive: true);
      });
      await tester.runAsync(() async {
        final store = await LibraryStore.create(root.path, 'Deletion test');
        for (var i = 0; i < 4; i++) {
          final file = await File(
            '${temp.path}/$i.png',
          ).writeAsBytes(img.encodePng(img.Image(width: 20 + i, height: 10)));
          await store.importImage(file.path);
        }
        await store.close();
      });
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const GalleryApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open library'));
      bool settled(int count) =>
          find.byType(GalleryTile).evaluate().length == count &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty;
      await until(tester, () => settled(4));
      await tester.tap(find.byType(GalleryTile).first);
      // Right-clicking an unselected tile targets that tile, not the old selection.
      await tester.tap(
        find.byType(GalleryTile).last,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await until(tester, () => settled(3));
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byType(GalleryTile).first);
      await tester.tap(find.byType(TextField).first);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(find.byType(GalleryTile), findsNWidgets(3));
      await tester.tap(find.byType(GalleryTile).first);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await until(tester, () => settled(2));
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byType(GalleryTile).first);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.byType(GalleryTile).last);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Delete 2 images?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await until(tester, () => settled(2));
      await tester.tap(
        find.byType(GalleryTile).first,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Delete 2 images?'), findsOneWidget);
      await tester.tap(find.text('Delete images'));
      await until(tester, () => settled(0));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close library'));
      await until(
        tester,
        () => find.text('Library closed').evaluate().isNotEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        final store = await LibraryStore.open(root.path);
        expect(await store.assets(), isEmpty);
        await store.close();
      });
    },
  );
}
