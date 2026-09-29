import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gallery_test/main.dart';
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
  testWidgets('star an image from its menu, then filter to starred', (
    tester,
  ) async {
    final previousPicker = FileSelectorPlatform.instance;
    final directory = Directory.systemTemp.createTempSync('umbra-star-');
    final root = Directory(p.join(directory.path, 'library'))..createSync();
    final picker = _Picker(root.path);
    picker.files = [
      for (var i = 0; i < 4; i++)
        XFile(
          (File(p.join(directory.path, 'image$i.png'))..writeAsBytesSync(
                img.encodePng(
                  img.fill(
                    img.Image(width: 40, height: 30),
                    color: img.ColorRgb8(40 * i, 60, 90),
                  ),
                ),
              ))
              .path,
        ),
    ];
    FileSelectorPlatform.instance = picker;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('umbra_tags/shell'),
      (call) async => true,
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
    await tester.enterText(find.byType(TextField), 'Stars');
    await tester.tap(find.text('Create'));
    await _until(
      tester,
      () => find.text('0 images').evaluate().isNotEmpty && _idle(),
    );
    await tester.tap(find.text('Import images'));
    await _until(
      tester,
      () => find.byType(GalleryTile).evaluate().length == 4 && _idle(),
    );

    final tiles = find.byType(GalleryTile);
    Finder starBadges() => find.descendant(
      of: find.byType(GalleryTile),
      matching: find.byIcon(Icons.star),
    );
    expect(starBadges(), findsNothing);
    // Imports leave the new images selected; select just one first.
    await tester.tap(tiles.at(1), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(
      tiles.at(1),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Star'));
    await _until(tester, () => starBadges().evaluate().length == 1 && _idle());

    // The menu now offers Unstar for that image.
    await tester.tap(
      tiles.at(1),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Unstar'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Starred'));
    await _until(
      tester,
      () => find.byType(GalleryTile).evaluate().length == 1 && _idle(),
    );
    await tester.tap(find.text('Starred'));
    await _until(
      tester,
      () => find.byType(GalleryTile).evaluate().length == 4 && _idle(),
    );

    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close library'));
    await _until(
      tester,
      () => find.text('Library closed').evaluate().isNotEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
}
