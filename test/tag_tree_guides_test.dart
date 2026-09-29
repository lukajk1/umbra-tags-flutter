import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gallery_test/widgets/tag_widgets.dart';

void main() {
  test('guides stop below the last child of each branch', () {
    // magic rpg
    // ├ env
    // │ └ hell
    // └ characters
    //   └ heroes
    // photos
    expect(tagTreeGuides([0, 1, 2, 1, 2, 0]), [
      <bool>[],
      [true], // env: characters follows, so its line continues (├)
      [true, false], // hell: env's branch continues; hell is last (└)
      [false], // characters: last child (└)
      [false, false], // heroes: nothing continues on either level
      <bool>[],
    ]);
  });
}
