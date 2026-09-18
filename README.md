# Umbra Tags — Flutter desktop

A desktop image gallery with portable, self-contained libraries.

## Use a library

1. Choose **New library** and select an empty writable folder, then name it.
2. Choose **Import images**. Originals are copied into the library; source files
   remain unchanged. Exact duplicates are skipped.
3. Use Crop, Fit or Masonry and the preview pane to browse. Edit → Archive selected
   hides images without deleting their originals; View → Show archive lets you restore them.
4. Close the library before moving or copying its folder. Open Library at the new
   location; tags and media references do not depend on the previous absolute path.

Every library contains `library.json`, `catalog.sqlite`, `media/`, generated `cache/`,
import `staging/`, and metadata `backups/`. Back Up Metadata does **not** back up media.
See [LIBRARY_FORMAT.md](LIBRARY_FORMAT.md) for the versioned schema and recovery contract.

## Development

```sh
flutter pub get
flutter run -d windows
flutter test
flutter analyze lib/main.dart lib/storage test
flutter build windows --release
```

On a Mac, use `flutter run -d macos` / `flutter build macos`. User-selected read/write
file entitlements are configured. Sandboxed Mac sessions currently require reselecting
the library folder; persistent security-scoped bookmarks are not implemented.

SQLite ships through the sqlite3 package's native assets. Storage, hashing, recovery,
and thumbnail decoding run in a dedicated worker isolate. Originals stay outside the
database. Only one cooperating application may edit a library at once.

## Scope

This is the new library/storage foundation, not a complete port of WinForms. The
catalog includes tables for tags, groups, predictions and jobs; their feature UIs and
classifier integration are future work. Legacy save conversion is intentionally deferred.
The standalone `lib/receiver_server.dart` experiment is not wired into library imports.
The current import flow supports JPEG, PNG, GIF, WebP and BMP, not videos.

Tests cover moving libraries, duplicate imports, archival, missing media restoration,
cache regeneration, backups, schema rejection, interrupted-import recovery, and the
create/import/preview/close/reopen UI flow. A widget-test screenshot is written to
`build/portable-library-ui.png` (Flutter's test font is intentionally non-production).
