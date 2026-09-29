import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gallery_test/main.dart';
import 'package:flutter_gallery_test/storage/tag_repository.dart';

void main() {
  testWidgets('dragging a tag onto a tile hands it to onTagDropped', (
    tester,
  ) async {
    final tag = LibraryTag.fromMap({
      'id': 't1',
      'name': 'Brutalist',
      'parent_id': null,
    });
    LibraryTag? dropped;
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            Draggable<LibraryTag>(
              data: tag,
              feedback: const Text('dragging'),
              child: const SizedBox(width: 100, height: 40, child: Text('tag')),
            ),
            SizedBox(
              width: 200,
              height: 200,
              child: GalleryTile(
                path: 'C:/library/a.png',
                thumbnail: Future.value(null),
                aspectRatio: 1,
                filename: 'a.png',
                tileSize: 200,
                layout: LayoutMode.crop,
                selected: true,
                onTap: () {},
                tagDropCount: 3,
                onTagDropped: (value) => dropped = value,
              ),
            ),
          ],
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('tag')),
    );
    await gesture.moveTo(tester.getCenter(find.byType(GalleryTile)));
    await tester.pump();
    expect(find.text('Add to 3 images'), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(dropped?.id, 't1');
    expect(find.text('Add to 3 images'), findsNothing);
  });
}
