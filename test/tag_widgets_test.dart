import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gallery_test/storage/library_store.dart';
import 'package:flutter_gallery_test/storage/tag_repository.dart';
import 'package:flutter_gallery_test/widgets/tag_widgets.dart';

void main() {
  testWidgets(
    'mixed tag selection applies only explicitly changed assignments',
    (tester) async {
      final tags = [
        LibraryTag.fromMap({'id': 'a', 'name': 'Mixed', 'parent_id': null}),
        LibraryTag.fromMap({'id': 'b', 'name': 'Unchanged', 'parent_id': null}),
      ];
      LibraryAsset asset(String id, List<String> ids) => LibraryAsset.fromMap({
        'id': id,
        'relative_path': 'media/$id.png',
        'original_filename': '$id.png',
        'width': 10,
        'height': 10,
        'sha256': 'hash',
        'tag_ids': ids,
      });
      List<String>? added, removed;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => BatchTagsDialog(
                    tags: tags,
                    assets: [
                      asset('1', ['a', 'b']),
                      asset('2', ['b']),
                    ],
                    onSave: (add, remove) async {
                      added = add;
                      removed = remove;
                    },
                  ),
                ),
                child: const Text('Edit'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('assign-tag-a')),
            )
            .value,
        isNull,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('assign-tag-b')),
            )
            .value,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('assign-tag-a')));
      await tester.pump();
      await tester.tap(find.text('Apply tags'));
      await tester.pumpAndSettle();
      expect(added, ['a']);
      expect(removed, isEmpty);
    },
  );
}
