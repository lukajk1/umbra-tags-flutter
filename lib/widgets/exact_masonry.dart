import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Tile rectangles for a masonry layout, placed shortest-column-first.
class MasonryLayout {
  const MasonryLayout(this.rects, this.height);
  final List<Rect> rects;
  final double height;

  factory MasonryLayout.compute(
    List<double> aspectRatios,
    double width,
    int columns,
    double spacing,
  ) {
    final columnWidth = math.max(
      0.0,
      (width - spacing * (columns - 1)) / columns,
    );
    final bottoms = List.filled(columns, 0.0);
    final rects = <Rect>[];
    for (final ratio in aspectRatios) {
      var column = 0;
      for (var c = 1; c < columns; c++) {
        if (bottoms[c] < bottoms[column]) column = c;
      }
      final valid = ratio.isFinite && ratio > 0 ? ratio : 1.0;
      final top = bottoms[column];
      final height = columnWidth / valid;
      rects.add(
        Rect.fromLTWH(
          column * (columnWidth + spacing),
          top,
          columnWidth,
          height,
        ),
      );
      bottoms[column] = top + height + spacing;
    }
    final tallest = bottoms.reduce(math.max);
    return MasonryLayout(
      rects,
      rects.isEmpty ? 0 : math.max(0, tallest - spacing),
    );
  }
}

/// A masonry grid whose full layout is computed from known aspect ratios, so
/// the scroll extent is exact from the start: dragging the scrollbar never
/// jumps as tiles load, unlike grids that estimate unbuilt tiles. Only tiles
/// within a viewport of the visible area are built.
class ExactMasonryView extends StatefulWidget {
  const ExactMasonryView({
    super.key,
    required this.controller,
    required this.aspectRatios,
    required this.columns,
    required this.spacing,
    required this.itemBuilder,
  });

  final ScrollController controller;
  final List<double> aspectRatios;
  final int columns;
  final double spacing;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<ExactMasonryView> createState() => _ExactMasonryViewState();
}

class _ExactMasonryViewState extends State<ExactMasonryView> {
  double _viewport = 0;
  int _band = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(ExactMasonryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  double get _offset =>
      widget.controller.hasClients ? widget.controller.offset : 0;

  // Rebuild only when the offset crosses into a new half-viewport band; the
  // built range extends a full viewport either side, so it stays covered.
  int _bandFor(double offset) =>
      _viewport > 0 ? (offset / (_viewport / 2)).floor() : 0;

  void _onScroll() {
    final band = _bandFor(_offset);
    if (band != _band) setState(() => _band = band);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _viewport = constraints.maxHeight;
      _band = _bandFor(_offset);
      final layout = MasonryLayout.compute(
        widget.aspectRatios,
        constraints.maxWidth,
        widget.columns,
        widget.spacing,
      );
      final top = _offset - _viewport;
      final bottom = _offset + _viewport * 2;
      return SingleChildScrollView(
        controller: widget.controller,
        child: SizedBox(
          width: constraints.maxWidth,
          height: layout.height,
          child: Stack(
            children: [
              for (var i = 0; i < layout.rects.length; i++)
                if (layout.rects[i].bottom >= top &&
                    layout.rects[i].top <= bottom)
                  Positioned.fromRect(
                    rect: layout.rects[i],
                    child: widget.itemBuilder(context, i),
                  ),
            ],
          ),
        ),
      );
    },
  );
}
