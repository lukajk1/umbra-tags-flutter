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

Flutter remembers the last library, Crop/Fit/Masonry layout, thumbnail size, preview
panel width and visibility, and scroll positions for each library/view. Preferences
are saved automatically after a short pause and when closing, in Flutter's own
`flutter-session.json` under the OS application-support directory. They are separate
from the legacy WinForms settings and the portable library catalog. Windows currently
resolves this to `%APPDATA%/Umbra Tags/Umbra Tags/Umbra Tags/flutter-session.json`.
Settings writes use a flushed temporary file followed by replacement; invalid optional
values fall back to defaults. macOS still requires selecting the library folder each
session to grant sandbox access.

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
app supports nested tags, batch assignment, and tag-based filtering. Tag groups and
classifier integration are future work; their storage tables already exist. Legacy save conversion is intentionally deferred.
The desktop app starts `lib/receiver_server.dart` automatically on IPv4 loopback port 8934.
The Chrome extension in `../web-beam` selects a library, tags and an optional longest-edge
size limit. Open each destination library in the app at least once, then refresh the
extension popup and save its destination. A browser icon in the status bar reports
receiver availability; hover for details. See `../web-beam/README.md` for setup and the protocol.
The current import flow supports JPEG, PNG, GIF, WebP and BMP, not videos.

Tests cover moving libraries, duplicate imports, archival, missing media restoration,
cache regeneration, backups, schema rejection, interrupted-import recovery, and the
create/import/preview/close/reopen UI flow. A widget-test screenshot is written to
`build/portable-library-ui.png` (Flutter's test font is intentionally non-production).

## Tagging

Select a gallery image and press **Delete**, or right-click it and choose **Delete**,
to permanently remove its library copy, thumbnail and metadata. Multiple selected
images require confirmation; a single image is deleted immediately. Right-clicking
an unselected image selects just that image. External source files and tag definitions
are kept. Delete only acts while the gallery has keyboard focus, not while editing text.

Use **+** in the Tags sidebar to create a tag. Its menu offers Add Child Tag,
Rename / Move, and Delete. Deletion removes that tag's assignments and moves its
children to its parent; it never deletes images. Tag names are globally unique
within the library (ASCII case insensitive).

Select images with click, Ctrl/Cmd-click, or marquee selection, then choose **Edit
tags** below the preview or **Edit → Edit tags…**. A dash means some selected images
have the tag. Changes apply to the whole selection; untouched assignments remain.

Click a sidebar tag to filter by that tag and all descendants. All Images and
Untagged exclude archived images; Archived shows only archived images. The tag search
field narrows the sidebar, not filenames. Existing libraries need no migration.
