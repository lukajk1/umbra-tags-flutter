import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gallery_test/main.dart';
import 'package:flutter_gallery_test/widgets/tag_widgets.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

class _Picker extends FileSelectorPlatform {
  _Picker(this.folder);
  final String folder;
  List<XFile> files = [];
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

bool _idle() => find.byType(CircularProgressIndicator).evaluate().isEmpty;

void main() {
  testWidgets(
    'a partly failing batch keeps its successes and recycles only them; '
    'imports in a tag view join that tag',
    (tester) async {
      final previousPicker = FileSelectorPlatform.instance;
      final directory = Directory.systemTemp.createTempSync('umbra-batch-');
      final root = Directory(p.join(directory.path, 'library'))..createSync();
      File picture(String name, int shade) {
        final image = img.Image(width: 40, height: 30);
        img.fill(image, color: img.ColorRgb8(shade, 60, 90));
        return File(p.join(directory.path, name))
          ..writeAsBytesSync(img.encodePng(image));
      }

      final good = picture('good.png', 10);
      final corrupt = File(p.join(directory.path, 'corrupt.png'))
        ..writeAsBytesSync([1, 2, 3, 4]);
      final alsoGood = picture('also-good.png', 200);
      final picker = _Picker(root.path);
      FileSelectorPlatform.instance = picker;
      final recycled = <List<String>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('umbra_tags/shell'),
        (call) async {
          if (call.method == 'recycleFiles') {
            recycled.add((call.arguments as List).cast<String>());
          }
          return true;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('umbra_tags/shell'),
          null,
        );
        FileSelectorPlatform.instance = previousPicker;
        directory.deleteSync(recursive: true);
      });
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(const GalleryApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('New library'));
      await _until(tester, () => find.text('Create').evaluate().isNotEmpty);
      await tester.enterText(find.byType(TextField), 'Batch');
      await tester.tap(find.text('Create'));
      await _until(
        tester,
        () => find.text('0 images').evaluate().isNotEmpty && _idle(),
      );

      picker.files = [
        XFile(good.path),
        XFile(corrupt.path),
        XFile(alsoGood.path),
      ];
      await tester.tap(find.text('Import images'));
      await _until(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      // The failure is reported, the successes are in the gallery, and only
      // the successful originals were sent to the Recycle Bin.
      expect(find.textContaining('corrupt.png'), findsOneWidget);
      expect(find.byType(GalleryTile), findsNWidgets(2));
      expect(recycled, [
        [p.absolute(good.path), p.absolute(alsoGood.path)],
      ]);
      await tester.tap(find.text('OK'));
      await _until(tester, _idle);

      // Create a tag, open its (empty) view, and import into it.
      await tester.tap(find.byTooltip('New tag'));
      await _until(
        tester,
        () => find.byType(TagDetailsDialog).evaluate().isNotEmpty,
      );
      await tester.enterText(
        find.descendant(
          of: find.byType(TagDetailsDialog),
          matching: find.byType(TextField),
        ),
        'Inbox',
      );
      await tester.tap(find.text('Save tag'));
      await _until(
        tester,
        () => find.byType(TagDetailsDialog).evaluate().isEmpty && _idle(),
      );
      await tester.tap(find.text('Inbox'));
      await _until(
        tester,
        () => find.byType(GalleryTile).evaluate().isEmpty && _idle(),
      );
      picker.files = [XFile(picture('new.png', 120).path)];
      await tester.tap(find.text('Import images'));
      await _until(
        tester,
        () => find.byType(GalleryTile).evaluate().length == 1 && _idle(),
      );
      expect(find.text('1 selected  '), findsOneWidget);

      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close library'));
      await _until(
        tester,
        () => find.text('Library closed').evaluate().isNotEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    },
  );
}
