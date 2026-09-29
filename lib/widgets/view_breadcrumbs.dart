import 'package:flutter/material.dart';

import '../storage/tag_repository.dart';
import 'tag_widgets.dart';

/// A strip above the gallery naming the open view, e.g.
/// "All images › magic rpg › env". Earlier crumbs navigate to that view.
class ViewBreadcrumbs extends StatelessWidget {
  const ViewBreadcrumbs({
    super.key,
    required this.tags,
    required this.view,
    required this.tagId,
    required this.onView,
    required this.onTag,
    this.starredOnly = false,
    this.onToggleStarred,
  });

  final List<LibraryTag> tags;
  final LibraryView view;
  final String? tagId;

  /// Null while navigation is unavailable (e.g. the app is busy).
  final ValueChanged<LibraryView>? onView;
  final ValueChanged<String>? onTag;

  /// The starred-only filter, shown as a toggle at the end of the strip.
  final bool starredOnly;
  final VoidCallback? onToggleStarred;

  @override
  Widget build(BuildContext context) {
    final byId = {for (final tag in tags) tag.id: tag};
    final chain = <LibraryTag>[];
    final seen = <String>{};
    for (var id = tagId; id != null && seen.add(id);) {
      final tag = byId[id];
      if (tag == null) break;
      chain.insert(0, tag);
      id = tag.parentId;
    }
    final crumbs = <(String, VoidCallback?)>[
      ('All images', onView == null ? null : () => onView!(LibraryView.all)),
      if (view == LibraryView.untagged) ('Untagged', null),
      if (view == LibraryView.archived) ('Archived', null),
      for (final tag in chain)
        (tag.name, onTag == null ? null : () => onTag!(tag.id)),
    ];
    return Container(
      height: 32,
      color: const Color(0xFF171717), // AppColors.darker, like the side panels
      padding: const EdgeInsets.only(left: 12, right: 8),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < crumbs.length; i++) ...[
                    if (i > 0)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 2),
                        child: Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: Colors.white38,
                        ),
                      ),
                    _Crumb(
                      label: crumbs[i].$1,
                      current: i == crumbs.length - 1,
                      onTap: crumbs[i].$2,
                    ),
                  ],
                ],
              ),
            ),
          ),
          _StarredToggle(on: starredOnly, onTap: onToggleStarred),
        ],
      ),
    );
  }
}

class _StarredToggle extends StatelessWidget {
  const _StarredToggle({required this.on, this.onTap});
  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: on ? 'Showing starred images only' : 'Show only starred images',
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              on ? Icons.star : Icons.star_outline,
              size: 16,
              color: on ? const Color(0xFFE8B63C) : Colors.white54,
            ),
            const SizedBox(width: 4),
            Text(
              'Starred',
              style: TextStyle(
                fontSize: 13,
                color: on ? Colors.white : Colors.white54,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Crumb extends StatelessWidget {
  const _Crumb({required this.label, required this.current, this.onTap});
  final String label;
  final bool current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      style: TextStyle(
        fontSize: 13,
        color: current ? Colors.white : Colors.white60,
        fontWeight: current ? FontWeight.w600 : FontWeight.normal,
      ),
    );
    if (current || onTap == null) {
      return Padding(padding: const EdgeInsets.all(4), child: text);
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(padding: const EdgeInsets.all(4), child: text),
    );
  }
}
