# Umbra Tags library format, version 1

A library is a self-contained folder. Open it by selecting the folder containing
`library.json` and `catalog.sqlite`. No required data lives in application settings.
This is a new format; legacy Calypso saves are deliberately not supported.

```
library.json             # format identity (UTF-8 JSON)
catalog.sqlite           # authoritative metadata, SQLite user_version = 1
media/<id-prefix>/<id>.<ext>
cache/thumbnails/<id>-<sha256>-v2.jpg
cache/previews/          # reserved, rebuildable
staging/                # recoverable import journals and temporary copies
backups/                # metadata-only SQLite snapshots
.umbra.lock              # persistent file used for an OS-held writer lock
```

## Manifest

```json
{
  "format": "umbra-tags-library",
  "formatVersion": 1,
  "libraryId": "a UUID shared with the library row"
}
```

The database library row owns the display name and creation time. Moving or renaming
the enclosing directory never changes the ID. A copied library retains its identity.
Creating an independent fork would require a future explicit operation.

## Catalog contract

`lib/storage/schema.dart` contains the complete canonical SQL DDL for a later Python
converter. UUIDs are text. All timestamps are UTC milliseconds since the Unix epoch.
Booleans are constrained SQLite integers, 0 or 1. Enable `PRAGMA foreign_keys=ON`
on every connection. Format and database versions are checked independently; unknown
versions are rejected without migration. The manifest ID must match the sole library row.

* `assets`: one record per original, with portable path, original filename, MIME type,
  dimensions after EXIF orientation, byte size, import/source dates, exact SHA-256,
  optional perceptual hash, archive and missing flags. SHA-256 is unique per library.
* `tag_groups`, `tags`, `asset_tags`: normalized organization. Tag hierarchy uses
  parent IDs; children and depth are derived. Future tag operations must additionally
  prevent multi-node cycles. SQLite NOCASE uniqueness is ASCII case insensitive.
* `predictions`: model/version, label, confidence, analyzed content hash, and date.
  Suggestions are separate from confirmed tags. No classifier is invoked yet.
* `jobs`: reserved durable job status/progress/errors. Running jobs become interrupted
  on reopen. Imports currently use their filesystem journal rather than this table.

Store paths using forward slashes, relative to the root, without `..`, drive prefixes,
or symlinks. Do not store absolute paths in catalog records. Library IDs and asset IDs
are independent of filenames, tags, and content hashes. Essential media remains an
ordinary file and is never embedded in SQLite. Media is immutable in this version.

## Import and recovery

1. Copy the source to `staging/<UUID>.part`. Source files are never moved or deleted.
2. Hash and decode the copy. Reject unsupported/undecodable images. The current import
   UI supports JPEG, PNG, GIF, WebP and BMP. Videos and editing are not implemented.
3. Exact duplicates return the existing asset; if its media is missing, restore that
   file from the copy. Archived duplicates remain archived.
4. Flush a `staging/<UUID>.json` journal containing the future asset row.
5. Rename the staged media into its ID-based location, then insert the row.
6. Remove the journal after the database commit.

Open replays completed journals, verifies bytes against SHA-256, and finishes interrupted
inserts. Malformed/conflicting journals stop opening and preserve files for recovery.
Unjournaled `.part` files are left alone after a crash, never silently deleted.
The journal covers process interruption; this is not a guarantee against every hardware
or filesystem failure. SQLite uses DELETE journaling and FULL synchronous mode.

## Cache, missing files, backups

Thumbnail requests are lazy, serialized in a worker isolate, and produce JPEGs with a
1280-pixel longest edge (JPEG quality 92), without enlarging smaller originals. The gallery uses a bounded map of requests and Flutter's image
cache. Deleting `cache/` while the app is closed is safe; it is recreated on demand.
Only the first frame is needed for gallery thumbnails; originals preserve animations.
Cache version suffix `v2` identifies the thumbnail recipe.

Refresh marks absent media `missing=1` without removing tags or records. This version
does not adopt files manually dropped into `media/`, detect external content edits, or
integrate the standalone Chrome receiver. Use Import Images for ingestion.

Back Up Metadata uses `VACUUM INTO` to create a consistent SQLite snapshot. It does
not copy originals and therefore is not a complete library backup. For a full portable
backup, close the library and copy the entire folder. Restore a catalog backup only
while the library is closed and retain the manifest with the matching ID.

## Concurrency and local preferences

One cooperating app may edit a library at a time. The OS file lock releases on close
or process exit; the `.umbra.lock` file remains and must not be deleted to bypass an
active lock. The Dart facade also blocks duplicate opens within the same process.
Network filesystems/cloud-sync live editing are not supported. Choose a writable local
or attached-drive folder with filesystem locking and rename support.

Flutter UI settings and the last-used folder live under the OS application-support
directory in `Umbra Tags/flutter-session.json`. These are conveniences, not library
data. Sandboxed macOS users reselect the library on each launch to grant access; durable
security-scoped bookmarks are not implemented. Both macOS entitlement files grant
user-selected read/write file access.

## Current UI

File: New Library (choose an empty folder), Open Library, Import Images, Back Up
Metadata, Close Library. Edit: Select All, Archive/Restore Selected. View: Archive,
Refresh Files, zoom. Existing crop/fit/masonry layouts and preview remain. No demo
images are loaded. Tag/classifier tables are storage foundations, not new editing UIs.
