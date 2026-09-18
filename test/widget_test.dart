import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gallery_test/main.dart';

void main() {
  testWidgets(
    'empty app exposes library creation and opening, not demo assets',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const GalleryApp());
      await tester.pumpAndSettle();
      expect(find.text('New library'), findsOneWidget);
      expect(find.text('Open library'), findsOneWidget);
      expect(find.text('Your images. Your library.'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    },
  );
}
