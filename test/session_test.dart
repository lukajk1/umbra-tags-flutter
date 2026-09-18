import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gallery_test/main.dart';
import 'package:flutter_gallery_test/storage/library_store.dart';
import 'package:image/image.dart' as img;

Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
    if (ready()) return;
  }
  fail('Session state did not settle');
}

void main() {
  testWidgets(
    'restores last library, layout, zoom, panel and scroll; saves changes across sessions',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('umbra-session-');
      final root = Directory('${temp.path}/library')..createSync();
      final session = File('${temp.path}/preferences.json');
      late String libraryId;
      await tester.runAsync(() async {
        final store = await LibraryStore.create(root.path, 'Session library');
        libraryId = store.id;
        for (var i = 0; i < 45; i++) {
          await store.importCapture(
            img.encodePng(img.Image(width: 50 + i, height: 50)),
            filename: '$i.png',
          );
        }
        await store.close();
      });
      session.writeAsStringSync(
        jsonEncode({
          'lastLibraryPath': root.path,
          'tileSize': 160,
          'layout': 'letterbox',
          'previewWidth': 360,
          'previewVisible': false,
          'scrollPositions': {'$libraryId/all': 200},
        }),
      );
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(GalleryApp(sessionFile: session));
      await until(
        tester,
        () =>
            find.byType(GridView).evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      final grid = tester.widget<GridView>(find.byType(GridView));
      await until(
        tester,
        () => grid.controller!.hasClients && grid.controller!.offset > 190,
      );
      expect(tester.widget<Slider>(find.byType(Slider)).value, 160);
      expect(
        tester
            .widget<SegmentedButton<LayoutMode>>(
              find.byType(SegmentedButton<LayoutMode>),
            )
            .selected,
        {LayoutMode.letterbox},
      );
      expect(find.byTooltip('Show preview'), findsOneWidget);
      await tester.tap(find.byTooltip('Show preview'));
      await tester.pump();
      final divider = find.byWidgetPredicate(
        (widget) =>
            widget is MouseRegion &&
            widget.cursor == SystemMouseCursors.resizeColumn,
      );
      await tester.drag(divider, const Offset(-60, 0));
      await tester.tap(
        find.byTooltip('Masonry — arrange by image proportions'),
      );
      await tester.pump();
      await tester.drag(find.byType(Slider), const Offset(25, 0));
      await tester.pump(const Duration(milliseconds: 500));
      await until(tester, () {
        final data = jsonDecode(session.readAsStringSync()) as Map;
        return data['layout'] == 'masonry' &&
            data['previewVisible'] == true &&
            (data['previewWidth'] as num) > 360;
      });
      final saved = jsonDecode(session.readAsStringSync()) as Map;
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close library'));
      await until(
        tester,
        () => find.text('Library closed').evaluate().isNotEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpWidget(GalleryApp(sessionFile: session));
      await until(
        tester,
        () =>
            find.text('Session library').evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      expect(
        tester
            .widget<SegmentedButton<LayoutMode>>(
              find.byType(SegmentedButton<LayoutMode>),
            )
            .selected,
        {LayoutMode.masonry},
      );
      expect(
        tester.widget<Slider>(find.byType(Slider)).value,
        saved['tileSize'],
      );
      expect(find.byTooltip('Hide preview'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close library'));
      await until(
        tester,
        () => find.text('Library closed').evaluate().isNotEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await until(tester, () => !File('${session.path}.tmp').existsSync());
      await tester.runAsync(() => temp.delete(recursive: true));
    },
  );
  testWidgets('invalid optional preferences fall back to usable defaults', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('umbra-session-invalid-');
    final session = File('${temp.path}/preferences.json')
      ..writeAsStringSync(
        jsonEncode({
          'tileSize': 'bad',
          'previewWidth': -10,
          'layout': 'future-layout',
          'previewVisible': false,
          'lastLibraryPath': 12,
        }),
      );
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(GalleryApp(sessionFile: session));
    await until(
      tester,
      () => find.byTooltip('Show preview').evaluate().isNotEmpty,
    );
    expect(tester.widget<Slider>(find.byType(Slider)).value, 200);
    expect(
      tester
          .widget<SegmentedButton<LayoutMode>>(
            find.byType(SegmentedButton<LayoutMode>),
          )
          .selected,
      {LayoutMode.crop},
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await until(tester, () => !File('${session.path}.tmp').existsSync());
    await tester.runAsync(() => temp.delete(recursive: true));
  });
}
