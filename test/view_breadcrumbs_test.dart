import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gallery_test/storage/tag_repository.dart';
import 'package:flutter_gallery_test/widgets/tag_widgets.dart';
import 'package:flutter_gallery_test/widgets/view_breadcrumbs.dart';

void main() {
  final tags = [
    for (final (id, name, parent) in [
      ('m', 'magic rpg', null),
      ('e', 'env', 'm'),
      ('h', 'hell', 'e'),
    ])
      LibraryTag.fromMap({'id': id, 'name': name, 'parent_id': parent}),
  ];

  Future<void> pump(
    WidgetTester tester, {
    LibraryView view = LibraryView.all,
    String? tagId,
    ValueChanged<LibraryView>? onView,
    ValueChanged<String>? onTag,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ViewBreadcrumbs(
          tags: tags,
          view: view,
          tagId: tagId,
          onView: onView,
          onTag: onTag,
        ),
      ),
    ),
  );

  testWidgets('nested tag shows its full chain; earlier crumbs navigate', (
    tester,
  ) async {
    final views = <LibraryView>[];
    final opened = <String>[];
    await pump(tester, tagId: 'h', onView: views.add, onTag: opened.add);
    for (final label in ['All images', 'magic rpg', 'env', 'hell']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('env'));
    await tester.tap(find.text('All images'));
    await tester.tap(find.text('hell')); // current view: not a link
    expect(opened, ['e']);
    expect(views, [LibraryView.all]);
  });

  testWidgets('untagged view', (tester) async {
    await pump(tester, view: LibraryView.untagged);
    expect(find.text('All images'), findsOneWidget);
    expect(find.text('Untagged'), findsOneWidget);
  });
}
