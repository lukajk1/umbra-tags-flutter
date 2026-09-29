import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gallery_test/widgets/exact_masonry.dart';

void main() {
  test('places tiles shortest-column-first with an exact total height', () {
    // Two 100px columns with 10px spacing: width 210.
    final layout = MasonryLayout.compute([1, 0.5, 2, 1], 210, 2, 10);
    expect(layout.rects, [
      const Rect.fromLTWH(0, 0, 100, 100), // col 0 -> bottom 110
      const Rect.fromLTWH(110, 0, 100, 200), // col 1 -> bottom 210
      const Rect.fromLTWH(0, 110, 100, 50), // col 0 -> bottom 170
      const Rect.fromLTWH(0, 170, 100, 100), // col 0 -> bottom 280
    ]);
    expect(layout.height, 270);
  });

  test('invalid aspect ratios fall back to square tiles', () {
    final layout = MasonryLayout.compute([0, double.infinity], 100, 1, 0);
    expect(layout.rects.map((r) => r.height), [100, 100]);
  });

  testWidgets('scroll extent is exact and only nearby tiles are built', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(210, 300));
    final controller = ScrollController();
    final built = <int>{};
    await tester.pumpWidget(
      MaterialApp(
        home: ExactMasonryView(
          controller: controller,
          aspectRatios: List.filled(200, 1.0),
          columns: 2,
          spacing: 10,
          itemBuilder: (context, index) {
            built.add(index);
            return Text('$index');
          },
        ),
      ),
    );
    // 100 rows of 100px with 10px gaps, minus the trailing gap, minus viewport.
    expect(controller.position.maxScrollExtent, 100 * 110 - 10 - 300);
    expect(built.every((i) => i < 12), isTrue);

    controller.jumpTo(5000);
    await tester.pump();
    expect(find.text('90'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    expect(controller.position.maxScrollExtent, 100 * 110 - 10 - 300);
  });
}
