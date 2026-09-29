import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../storage/library_store.dart';
import '../storage/tag_repository.dart';
import '../ml/tag_suggester.dart';
import 'tag_suggestions_panel.dart';

enum LibraryView { all, untagged, archived }

List<({LibraryTag tag, int depth})> tagTree(List<LibraryTag> tags) {
  final result = <({LibraryTag tag, int depth})>[];
  final seen = <String>{};
  void visit(String? parent, int depth) {
    for (final tag in tags.where((t) => t.parentId == parent)) {
      if (!seen.add(tag.id)) continue;
      result.add((tag: tag, depth: depth));
      visit(tag.id, depth + 1);
    }
  }

  visit(null, 0);
  // Keep externally malformed orphan tags visible instead of silently losing them.
  for (final tag in tags) {
    if (seen.add(tag.id)) result.add((tag: tag, depth: 0));
  }
  return result;
}

/// For each row of a displayed tag tree (given as depths, parents first),
/// which guide lines continue below it: entry k is true when the row's
/// ancestor at depth k + 1, or for the last entry the row itself, has a later
/// sibling. Rows at depth 0 get an empty list.
List<List<bool>> tagTreeGuides(List<int> depths) {
  bool hasNextSibling(int index) {
    for (var j = index + 1; j < depths.length; j++) {
      if (depths[j] < depths[index]) return false;
      if (depths[j] == depths[index]) return true;
    }
    return false;
  }

  final continuing = <bool>[];
  return [
    for (var i = 0; i < depths.length; i++)
      () {
        final depth = depths[i];
        // Keep ancestors' entries, replace this depth's with this row's.
        if (continuing.length > depth) {
          continuing.removeRange(depth, continuing.length);
        }
        while (continuing.length < depth) {
          continuing.add(false);
        }
        continuing.add(hasNextSibling(i));
        return [for (var k = 1; k <= depth; k++) continuing[k]];
      }(),
  ];
}

/// Indents a tag row by its depth and draws tree guides from its ancestors,
/// so nesting reads at a glance: ├ for a child with siblings below, └ for the
/// last child, and ancestor lines only while that branch continues.
/// [continues] comes from [tagTreeGuides]; its length is the row's depth.
/// [origin] is the x offset of the row's leading control (e.g. a checkbox)
/// centre, which the guides line up with.
class TagTreeIndent extends StatelessWidget {
  const TagTreeIndent({
    super.key,
    required this.continues,
    required this.child,
    this.step = 24,
    this.origin = 28,
  });
  final List<bool> continues;
  final Widget child;
  final double step, origin;

  @override
  Widget build(BuildContext context) => continues.isEmpty
      ? child
      : IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: continues.length * step,
                child: CustomPaint(
                  painter: _TagTreePainter(
                    continues: continues,
                    step: step,
                    origin: origin,
                    color: Colors.white38,
                  ),
                ),
              ),
              Expanded(child: child),
            ],
          ),
        );
}

class _TagTreePainter extends CustomPainter {
  _TagTreePainter({
    required this.continues,
    required this.step,
    required this.origin,
    required this.color,
  });
  final List<bool> continues;
  final double step, origin;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    final depth = continues.length;
    final y = size.height / 2;
    // Ancestor levels: a full-height line only while that branch continues.
    for (var level = 0; level < depth - 1; level++) {
      if (!continues[level]) continue;
      final x = level * step + origin;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    // This row's own branch: down to the elbow, and on only if a sibling
    // follows. The elbow runs to just before this row's control; the canvas
    // is not clipped, so it may reach past the indent into the row.
    final parentX = (depth - 1) * step + origin;
    canvas.drawLine(
      Offset(parentX, 0),
      Offset(parentX, continues.last ? size.height : y),
      paint,
    );
    canvas.drawLine(
      Offset(parentX, y),
      Offset(depth * step + origin - 13, y),
      paint,
    );
  }

  @override
  bool shouldRepaint(_TagTreePainter old) =>
      !listEquals(old.continues, continues) ||
      old.step != step ||
      old.origin != origin ||
      old.color != color;
}

class TagSidebar extends StatefulWidget {
  const TagSidebar({
    super.key,
    required this.tags,
    required this.view,
    required this.selectedTag,
    required this.busy,
    required this.onView,
    required this.onSelect,
    required this.onCreate,
    required this.onEdit,
    required this.onDelete,
    this.onFindMatches,
    this.onToggleExcluded,
  });
  final List<LibraryTag> tags;
  final LibraryView view;
  final String? selectedTag;
  final bool busy;
  final ValueChanged<LibraryView> onView;
  final ValueChanged<String> onSelect;
  final ValueChanged<String?> onCreate;
  final ValueChanged<LibraryTag> onEdit, onDelete;
  final ValueChanged<LibraryTag>? onFindMatches;

  /// Toggles whether the tag's images are left out of All images.
  final ValueChanged<LibraryTag>? onToggleExcluded;
  @override
  State<TagSidebar> createState() => _TagSidebarState();
}

class _TagSidebarState extends State<TagSidebar> {
  String _search = '';
  void _tagAction(String action, LibraryTag tag) {
    if (action == 'child') widget.onCreate(tag.id);
    if (action == 'edit') widget.onEdit(tag);
    if (action == 'delete') widget.onDelete(tag);
    if (action == 'match') widget.onFindMatches?.call(tag);
    if (action == 'exclude') widget.onToggleExcluded?.call(tag);
  }

  List<PopupMenuEntry<String>> _menuItems(LibraryTag tag) => [
    if (widget.onFindMatches != null)
      const PopupMenuItem(value: 'match', child: Text('Find matching images…')),
    if (widget.onToggleExcluded != null)
      PopupMenuItem(
        value: 'exclude',
        child: Text(
          tag.excludedFromAll
              ? 'Show in All images'
              : 'Exclude from All images',
        ),
      ),
    PopupMenuItem(value: 'child', child: Text('Add child tag')),
    PopupMenuItem(value: 'edit', child: Text('Rename / move')),
    PopupMenuItem(value: 'delete', child: Text('Delete tag')),
  ];

  @override
  Widget build(BuildContext context) {
    final rows = tagTree(widget.tags)
        .where((r) => r.tag.name.toLowerCase().contains(_search.toLowerCase()))
        .toList();
    return SizedBox(
      width: 220,
      child: ColoredBox(
        color: const Color(0xff171717),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            for (final (view, title, icon) in [
              (LibraryView.all, 'All images', Icons.photo_library_outlined),
              (LibraryView.untagged, 'Untagged', Icons.label_off_outlined),
              (LibraryView.archived, 'Archived', Icons.archive_outlined),
            ])
              ListTile(
                dense: true,
                leading: Icon(icon, size: 19),
                title: Text(
                  title,
                  style: const TextStyle(
                    fontFamily: 'LibreBaskerville',
                    fontWeight: FontWeight.w400,
                  ),
                ),
                selected: widget.view == view && widget.selectedTag == null,
                onTap: widget.busy ? null : () => widget.onView(view),
              ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'TAGS',
                      style: TextStyle(fontSize: 12, color: Colors.white60),
                    ),
                  ),
                  IconButton(
                    tooltip: 'New tag',
                    onPressed: widget.busy ? null : () => widget.onCreate(null),
                    icon: const Icon(Icons.add, size: 20),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                onChanged: (value) => setState(() => _search = value),
                decoration: const InputDecoration(
                  hintText: 'Find a tag',
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: rows.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        widget.tags.isEmpty
                            ? 'Create a tag to start organizing.'
                            : 'No matching tags',
                        style: const TextStyle(color: Colors.white54),
                      ),
                    )
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onSecondaryTapUp: widget.busy
                              ? null
                              : (details) async {
                                  final overlay =
                                      Overlay.of(
                                            context,
                                          ).context.findRenderObject()
                                          as RenderBox;
                                  final position = overlay.globalToLocal(
                                    details.globalPosition,
                                  );
                                  final action = await showMenu<String>(
                                    context: context,
                                    position: RelativeRect.fromRect(
                                      Rect.fromLTWH(
                                        position.dx,
                                        position.dy,
                                        0,
                                        0,
                                      ),
                                      Offset.zero & overlay.size,
                                    ),
                                    items: _menuItems(row.tag),
                                  );
                                  if (mounted &&
                                      !widget.busy &&
                                      action != null) {
                                    _tagAction(action, row.tag);
                                  }
                                },
                          // Drag a tag onto gallery images to assign it.
                          child: Draggable<LibraryTag>(
                            data: row.tag,
                            maxSimultaneousDrags: widget.busy ? 0 : 1,
                            dragAnchorStrategy: pointerDragAnchorStrategy,
                            feedback: _TagDragFeedback(name: row.tag.name),
                            child: ListTile(
                              key: ValueKey('tag-filter-${row.tag.id}'),
                              dense: true,
                              contentPadding: EdgeInsets.only(
                                left:
                                    12 +
                                    (row.depth * 12).clamp(0, 60).toDouble(),
                              ),
                              leading: row.tag.excludedFromAll
                                  ? const Tooltip(
                                      message: 'Excluded from All images',
                                      child: Icon(
                                        Icons.visibility_off_outlined,
                                        size: 18,
                                      ),
                                    )
                                  : const Icon(Icons.label_outline, size: 18),
                              minLeadingWidth: 16,
                              title: Tooltip(
                                message: row.tag.name,
                                child: Text.rich(
                                  TextSpan(
                                    text: row.tag.name,
                                    children: [
                                      TextSpan(
                                        text: ' (${row.tag.assetCount})',
                                        style: const TextStyle(
                                          color: Colors.white54,
                                        ),
                                      ),
                                    ],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              selected: widget.selectedTag == row.tag.id,
                              onTap: widget.busy
                                  ? null
                                  : () => widget.onSelect(row.tag.id),
                              trailing: PopupMenuButton<String>(
                                tooltip: 'Manage ${row.tag.name}',
                                enabled: !widget.busy,
                                icon: const Icon(Icons.more_vert, size: 18),
                                onSelected: (action) =>
                                    _tagAction(action, row.tag),
                                itemBuilder: (_) => _menuItems(row.tag),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TagDragFeedback extends StatelessWidget {
  const _TagDragFeedback({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) => Transform.translate(
    offset: const Offset(12, 8),
    child: Material(
      color: const Color(0xFF262622),
      elevation: 6,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.label_outline, size: 16),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    ),
  );
}

class TagDetailsDialog extends StatefulWidget {
  const TagDetailsDialog({
    super.key,
    required this.tags,
    required this.onSave,
    this.tag,
    this.parentId,
  });
  final List<LibraryTag> tags;
  final LibraryTag? tag;
  final String? parentId;
  final Future<void> Function(String name, String? parent) onSave;
  @override
  State<TagDetailsDialog> createState() => _TagDetailsDialogState();
}

class _TagDetailsDialogState extends State<TagDetailsDialog> {
  late final _name = TextEditingController(text: widget.tag?.name ?? '');
  late String? _parent = widget.tag?.parentId ?? widget.parentId;
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(_name.text, _parent);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final excluded = <String>{if (widget.tag != null) widget.tag!.id};
    var changed = true;
    while (changed) {
      changed = false;
      for (final tag in widget.tags) {
        if (excluded.contains(tag.parentId) && excluded.add(tag.id)) {
          changed = true;
        }
      }
    }
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(widget.tag == null ? 'New tag' : 'Edit tag'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                enabled: !_saving,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Tag name'),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _parent ?? '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Parent tag'),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('None — top level'),
                  ),
                  for (final row in tagTree(
                    widget.tags,
                  ).where((r) => !excluded.contains(r.tag.id)))
                    DropdownMenuItem(
                      value: row.tag.id,
                      child: Text(
                        '${'  ' * row.depth}${row.tag.name}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (value) =>
                          setState(() => _parent = value == '' ? null : value),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save tag'),
          ),
        ],
      ),
    );
  }
}

class BatchTagsDialog extends StatefulWidget {
  const BatchTagsDialog({
    super.key,
    required this.tags,
    required this.assets,
    required this.onSave,
    this.onSuggest,
    this.thumbnail,
    this.onApplyReviewed,
  });
  final List<LibraryTag> tags;
  final List<LibraryAsset> assets;
  final Future<void> Function(List<String> add, List<String> remove) onSave;
  final Future<List<TagSuggestion>> Function(LibraryAsset)? onSuggest;
  final Future<String?> Function(LibraryAsset)? thumbnail;
  final Future<void> Function(
    List<String> add,
    List<String> remove,
    Map<String, List<String>> accepted,
  )?
  onApplyReviewed;
  @override
  State<BatchTagsDialog> createState() => _BatchTagsDialogState();
}

class _BatchTagsDialogState extends State<BatchTagsDialog> {
  final Map<String, bool> _changes = {};
  final Map<String, Set<String>> _accepted = {};
  String _search = '';
  String? _error;
  bool _saving = false;
  bool? _value(String id) {
    if (_changes.containsKey(id)) return _changes[id];
    final count = widget.assets.where((a) => a.tagIds.contains(id)).length;
    return count == 0
        ? false
        : count == widget.assets.length
        ? true
        : null;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final add = _changes.entries
          .where((e) => e.value)
          .map((e) => e.key)
          .toList();
      final remove = _changes.entries
          .where((e) => !e.value)
          .map((e) => e.key)
          .toList();
      if (widget.onApplyReviewed != null) {
        await widget.onApplyReviewed!(add, remove, {
          for (final entry in _accepted.entries)
            if (entry.value.isNotEmpty) entry.key: entry.value.toList(),
        });
      } else {
        await widget.onSave(add, remove);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = tagTree(widget.tags)
        .where((r) => r.tag.name.toLowerCase().contains(_search.toLowerCase()))
        .toList();
    final guides = tagTreeGuides([for (final row in rows) row.depth]);
    final canSuggest =
        widget.onSuggest != null &&
        widget.thumbnail != null &&
        widget.onApplyReviewed != null;
    final manual = Column(
      children: [
        const Text(
          'A dash means only some images have this tag. Unchanged tags are preserved.',
          style: TextStyle(color: Colors.white60),
        ),
        TextField(
          onChanged: (value) => setState(() => _search = value),
          decoration: const InputDecoration(
            hintText: 'Find a tag',
            prefixIcon: Icon(Icons.search),
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? const Center(child: Text('No matching tags'))
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    return TagTreeIndent(
                      continues: guides[index],
                      child: CheckboxListTile(
                        key: ValueKey('assign-tag-${row.tag.id}'),
                        title: Text(
                          row.tag.name,
                          style: row.depth == 0
                              ? const TextStyle(fontWeight: FontWeight.w600)
                              : null,
                        ),
                        contentPadding: const EdgeInsets.only(
                          left: 8,
                          right: 16,
                        ),
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        tristate: true,
                        value: _value(row.tag.id),
                        onChanged: _saving
                            ? null
                            : (_) => setState(
                                () => _changes[row.tag.id] =
                                    _value(row.tag.id) != true,
                              ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text('Tags · ${widget.assets.length} selected'),
        content: SizedBox(
          width: 560,
          height: 540,
          child: Column(
            children: [
              Expanded(
                child: canSuggest
                    ? DefaultTabController(
                        length: 2,
                        initialIndex: widget.tags.isEmpty ? 1 : 0,
                        child: Column(
                          children: [
                            const TabBar(
                              tabs: [
                                Tab(text: 'Existing tags'),
                                Tab(text: 'Suggestions'),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: TabBarView(
                                children: [
                                  manual,
                                  TagSuggestionsPanel(
                                    assets: widget.assets,
                                    tags: widget.tags,
                                    onSuggest: widget.onSuggest!,
                                    thumbnail: widget.thumbnail!,
                                    accepted: _accepted,
                                    saving: _saving,
                                    onChanged: () => setState(() {}),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      )
                    : manual,
              ),
              if (_accepted.values.any((names) => names.isNotEmpty))
                Text(
                  '${_accepted.values.fold<int>(0, (sum, names) => sum + names.length)} suggestions selected',
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed:
                _saving ||
                    (_changes.isEmpty &&
                        _accepted.values.every((names) => names.isEmpty))
                ? null
                : _save,
            child: Text(_saving ? 'Saving…' : 'Apply tags'),
          ),
        ],
      ),
    );
  }
}

class SelectionTags extends StatelessWidget {
  const SelectionTags({super.key, required this.tags, required this.assets});
  final List<LibraryTag> tags;
  final List<LibraryAsset> assets;
  @override
  Widget build(BuildContext context) {
    final assigned = [
      for (final tag in tags)
        (
          tag: tag,
          count: assets.where((a) => a.tagIds.contains(tag.id)).length,
        ),
    ].where((item) => item.count > 0).toList();
    return Container(
      constraints: const BoxConstraints(maxHeight: 190),
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Tags'),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: assigned.isEmpty
                  ? const Text(
                      'No tags assigned',
                      style: TextStyle(color: Colors.white54),
                    )
                  : Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final item in assigned)
                          Chip(
                            label: Text(
                              '${item.tag.name}${item.count < assets.length ? ' · ${item.count}/${assets.length}' : ''}',
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
