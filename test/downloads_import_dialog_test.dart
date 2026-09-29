import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gallery_test/widgets/downloads_import_dialog.dart';

void main() {
  testWidgets('returns only the chosen files, in listing order', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    final files = [
      for (final name in ['newest.png', 'middle.jpg', 'oldest.webp'])
        File('C:/Downloads/$name'),
    ];
    List<String>? chosen;
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              chosen = await showDialog<List<String>>(
                context: context,
                builder: (_) => DownloadsImportDialog(
                  folder: 'C:/Downloads',
                  files: files,
                  accent: Colors.red,
                  onOpen: opened.add,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final import = find.widgetWithText(FilledButton, 'Import');
    expect(tester.widget<FilledButton>(import).onPressed, isNull);

    // Select oldest, then newest; toggle middle on and off again.
    await tester.tap(find.text('oldest.webp'));
    await tester.tap(find.text('newest.png'));
    await tester.tap(find.text('middle.jpg'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('middle.jpg'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Import 2'));
    await tester.pumpAndSettle();
    expect(chosen, ['C:/Downloads/newest.png', 'C:/Downloads/oldest.webp']);
    expect(opened, isEmpty);
  });

  testWidgets('cancel returns nothing', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    Object? chosen = 'unset';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              chosen = await showDialog<List<String>>(
                context: context,
                builder: (_) => DownloadsImportDialog(
                  folder: 'C:/Downloads',
                  files: [File('C:/Downloads/a.png')],
                  accent: Colors.red,
                  onOpen: (_) {},
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select all'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(chosen, isNull);
  });
}
