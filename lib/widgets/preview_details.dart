import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../storage/library_store.dart';

/// Horizontal inset shared by every section of the preview panel.
const previewInset = 16.0;

/// Filename, then one line of dimensions and import date.
class PreviewDetails extends StatelessWidget {
  const PreviewDetails({
    super.key,
    required this.asset,
    required this.selectionCount,
  });
  final LibraryAsset asset;
  final int selectionCount;

  @override
  Widget build(BuildContext context) {
    final extension = p.extension(asset.originalFilename);
    final stem = extension.isEmpty
        ? asset.originalFilename
        : p.basenameWithoutExtension(asset.originalFilename);
    final localizations = MaterialLocalizations.of(context);
    final added = asset.importedAt;
    final fullDate = added == null
        ? 'Unknown import date'
        : '${localizations.formatFullDate(added)} · ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(added))}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(previewInset, 12, previewInset, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Tooltip(
            message: asset.originalFilename,
            child: Semantics(
              label: asset.originalFilename,
              excludeSemantics: true,
              child: DefaultTextStyle.merge(
                style: const TextStyle(fontWeight: FontWeight.w600),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        stem,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(extension, maxLines: 1),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Tooltip(
            message: fullDate,
            child: Text(
              '${asset.width} × ${asset.height} px · '
              'Added ${added == null ? '—' : localizations.formatShortDate(added)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ),
          if (selectionCount > 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Previewing 1 of $selectionCount selected',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

/// Full-width action at the bottom of the preview panel.
class OpenExternallyButton extends StatelessWidget {
  const OpenExternallyButton({super.key, required this.onOpen});
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(previewInset, 0, previewInset, 16),
    child: OutlinedButton.icon(
      onPressed: onOpen,
      icon: const Icon(Icons.open_in_new, size: 16),
      label: const Text(
        'Open in external viewer',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}
