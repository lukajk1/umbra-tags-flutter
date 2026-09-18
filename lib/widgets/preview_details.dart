import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../storage/library_store.dart';

class PreviewDetails extends StatelessWidget {
  const PreviewDetails({
    super.key,
    required this.asset,
    required this.selectionCount,
    required this.onOpen,
  });
  final LibraryAsset asset;
  final int selectionCount;
  final VoidCallback? onOpen;

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
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
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
          const SizedBox(height: 6),
          Text(
            '${asset.width} × ${asset.height} px',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 2),
          Tooltip(
            message: fullDate,
            child: Text(
              'Added ${added == null ? '—' : localizations.formatShortDate(added)}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
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
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: OutlinedButton(
              onPressed: onOpen,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.open_in_new, size: 16),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Open in ext. viewer',
                      maxLines: 2,
                      textAlign: TextAlign.center,
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
