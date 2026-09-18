import 'package:flutter/material.dart';
import '../storage/library_store.dart';
import '../storage/tag_repository.dart';

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
  });
  final List<LibraryTag> tags;
  final LibraryView view;
  final String? selectedTag;
  final bool busy;
  final ValueChanged<LibraryView> onView;
  final ValueChanged<String> onSelect;
  final ValueChanged<String?> onCreate;
  final ValueChanged<LibraryTag> onEdit, onDelete;
  @override
  State<TagSidebar> createState() => _TagSidebarState();
}

class _TagSidebarState extends State<TagSidebar> {
  String _search = '';
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
                title: Text(title),
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
                        return ListTile(
                          key: ValueKey('tag-filter-${row.tag.id}'),
                          dense: true,
                          contentPadding: EdgeInsets.only(
                            left: 12 + (row.depth * 12).clamp(0, 60).toDouble(),
                          ),
                          leading: const Icon(Icons.label_outline, size: 18),
                          minLeadingWidth: 16,
                          title: Tooltip(
                            message: row.tag.name,
                            child: Text(
                              row.tag.name,
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
                            onSelected: (action) {
                              if (action == 'child') {
                                widget.onCreate(row.tag.id);
                              }
                              if (action == 'edit') widget.onEdit(row.tag);
                              if (action == 'delete') widget.onDelete(row.tag);
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'child',
                                child: Text('Add child tag'),
                              ),
                              PopupMenuItem(
                                value: 'edit',
                                child: Text('Rename / move'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete tag'),
                              ),
                            ],
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
  });
  final List<LibraryTag> tags;
  final List<LibraryAsset> assets;
  final Future<void> Function(List<String> add, List<String> remove) onSave;
  @override
  State<BatchTagsDialog> createState() => _BatchTagsDialogState();
}

class _BatchTagsDialogState extends State<BatchTagsDialog> {
  final Map<String, bool> _changes = {};
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
      await widget.onSave(
        _changes.entries.where((e) => e.value).map((e) => e.key).toList(),
        _changes.entries.where((e) => !e.value).map((e) => e.key).toList(),
      );
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
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text('Tags · ${widget.assets.length} selected'),
        content: SizedBox(
          width: 400,
          height: 380,
          child: Column(
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
                          return CheckboxListTile(
                            key: ValueKey('assign-tag-${row.tag.id}'),
                            title: Text('${'  ' * row.depth}${row.tag.name}'),
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
                          );
                        },
                      ),
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
            onPressed: _saving || _changes.isEmpty ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Apply tags'),
          ),
        ],
      ),
    );
  }
}

class SelectionTags extends StatelessWidget {
  const SelectionTags({
    super.key,
    required this.tags,
    required this.assets,
    required this.onEdit,
  });
  final List<LibraryTag> tags;
  final List<LibraryAsset> assets;
  final VoidCallback? onEdit;
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
          Row(
            children: [
              const Expanded(child: Text('Tags')),
              TextButton(onPressed: onEdit, child: const Text('Edit tags')),
            ],
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
