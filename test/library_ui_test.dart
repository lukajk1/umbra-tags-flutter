import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gallery_test/main.dart';
import 'package:flutter_gallery_test/storage/library_store.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

class _Picker extends FileSelectorPlatform {
  _Picker(this.folder, this.files);
  final String folder;
  final List<XFile> files;
  @override
  Future<String?> getDirectoryPathWithOptions(
    FileDialogOptions options,
  ) async => folder;
  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => files;
}

Future<void> _until(WidgetTester tester, bool Function() predicate) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
    if (predicate()) return;
  }
  fail('Library UI did not reach the expected state.');
}

void main() {
  testWidgets('create, import, preview, close and reopen through the app', (
    tester,
  ) async {
    final previousPicker = FileSelectorPlatform.instance;
    final directory = Directory.systemTemp.createTempSync('umbra-ui-');
    final root = Directory(p.join(directory.path, 'library'))..createSync();
    final picture = img.Image(width: 320, height: 200);
    img.fill(picture, color: img.ColorRgb8(120, 65, 35));
    final source = File(p.join(directory.path, 'sample.png'))
      ..writeAsBytesSync(img.encodePng(picture));
    FileSelectorPlatform.instance = _Picker(root.path, [XFile(source.path)]);
    addTearDown(() {
      FileSelectorPlatform.instance = previousPicker;
      directory.deleteSync(recursive: true);
    });
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final screenshotKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: screenshotKey, child: const GalleryApp()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('New library'));
    await _until(tester, () => find.text('Create').evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextField), 'Portable Library');
    await tester.tap(find.text('Create'));
    await _until(
      tester,
      () =>
          find.text('0 images').evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    expect(File(p.join(root.path, 'library.json')).existsSync(), isTrue);
    await tester.tap(find.text('Import images'));
    await _until(
      tester,
      () =>
          find.byType(GalleryTile).evaluate().length == 1 &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    await _until(
      tester,
      () => tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((image) => image.image != null),
    );
    await tester.tap(find.byType(GalleryTile));
    await tester.pump(const Duration(milliseconds: 300));
    await _until(
      tester,
      () =>
          tester
              .widgetList<RawImage>(find.byType(RawImage))
              .where((image) => image.image != null)
              .length ==
          2,
    );
    expect(find.text('1 selected  '), findsOneWidget);
    expect(source.existsSync(), isTrue);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          screenshotKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final target = File(p.join('build', 'portable-library-ui.png'));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close library'));
    await _until(
      tester,
      () => find.text('Library closed').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Open library'));
    await _until(
      tester,
      () =>
          find.byType(GalleryTile).evaluate().length == 1 &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close library'));
    await _until(
      tester,
      () => find.text('Library closed').evaluate().isNotEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(() async {
      final store = await LibraryStore.open(root.path);
      expect((await store.assets()).single.originalFilename, 'sample.png');
      await store.close();
    });
  });
}
