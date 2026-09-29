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
advanced classifier workflows are future work. Local ML classification is available through the gallery context menu. Legacy save conversion is intentionally deferred.
The desktop app starts `lib/receiver_server.dart` automatically on IPv4 loopback port 8934.
The Chrome extension in `../umbra-tags-extension` selects a library, tags and an optional longest-edge
size limit. Open each destination library in the app at least once, then refresh the
extension popup and save its destination. A browser icon in the status bar reports
receiver availability; hover for details. See `../umbra-tags-extension/README.md` for setup and the protocol.
The current import flow supports JPEG, PNG, GIF, WebP and BMP, not videos.

Tests cover moving libraries, duplicate imports, archival, missing media restoration,
cache regeneration, backups, schema rejection, interrupted-import recovery, and the
create/import/preview/close/reopen UI flow. A widget-test screenshot is written to
`build/portable-library-ui.png` (Flutter's test font is intentionally non-production).

## ML classification

Right-click an image or selected batch and choose **ML classify**. The app starts
the local Python worker from the sibling `umbra-tags-ml` project and defaults to
the newer `best_model.pth` artwork/photos classifier. **Edit → Options → Machine learning** switches
models and configures the confidence threshold (80% by default), automatic tagging,
ML folder and Python executable. All settings persist between sessions.

Prediction scores and model/image hashes are saved separately from assigned tags.
Confident results create/reuse a named tag and assign it; existing tags are kept.
`LibraryStore.tagAssetsByName`, `applyClassification` and `predictions` expose the
same operations to code. Inference implements the replaceable `ImageClassifier`
interface; Python architectures are selected through `umbra-tags-ml/models.json`.
See `../umbra-tags-ml/README.md` for setup, the adapter protocol and code examples.

## Tagging and deletion

Select a gallery image and press **Delete**, or right-click it and choose **Delete**,
to permanently remove its library copy, thumbnail and metadata. Multiple selected
images require confirmation; a single image is deleted immediately. Right-clicking
an unselected image selects just that image. External source files and tag definitions
are kept. Delete only acts while the gallery has keyboard focus, not while editing text.

Use **+** in the Tags sidebar to create a tag. Its menu offers Add Child Tag,
Rename / Move, and Delete. Deletion removes that tag's assignments and moves its
children to its parent; it never deletes images. Tag names are globally unique
within the library (ASCII case insensitive).

Select images with click, Ctrl/Cmd-click, Shift-click for a range in gallery order
(Ctrl+Shift adds the range), or Alt + drag for a selection box, then choose **Edit →
Edit tags…** or **Edit tags…** from an image's right-click menu. A dash means some selected images
have the tag. Changes apply to the whole selection; untouched assignments remain.

A tag's ⋮ menu offers **Exclude from All images**: images with that tag or its
children are then left out of All images (the tag shows an eye-slash icon), while
its own tag view, Untagged and Archived are unchanged. Choose **Show in All
images** to undo it. This setting needs catalog v3; libraries upgrade on open.

Drag an image without Alt to drop it, or the whole selection when it is part of
one, into other applications as files (Explorer, chat apps, browser uploads).
Drops always copy, so library files are never moved out. On Windows,
**File → Import from Downloads…** lists the images in Downloads (newest first) to
pick from. Every import from disk moves the originals to the Recycle Bin once they
are safely in the library; files already inside the library folder are left alone.

Click a sidebar tag to filter by that tag and all descendants. All Images and
Untagged exclude archived images; Archived shows only archived images. The tag search
field narrows the sidebar, not filenames. Existing libraries need no migration.


## Find similar images

Right-click an image → **Find similar**. Missing embeddings for the query image
are prioritized. Results update while other images are indexed, and show indexed
coverage instead of claiming to search the full library before it is ready.
Double-click a result to open it in the system viewer. The bottom status bar opens
index details, pause/resume, error details and retry. Imports from disk, drag/drop
and the extension join the open library's background queue automatically.

The default bundled model is Google's SigLIP 2 Base (224px vision encoder).
Inference is local, CPU-based, limited to two Torch threads. First launch loads
local weights; there is no runtime network download. Python lives outside Flutter,
cosine search lives in the storage isolate, and the embedder interface is swappable.
Indexing pauses between images while interactive library operations run. Archived
or missing images are excluded. The first animation frame is embedded.

### Offline Windows distribution

Build with `flutter build windows --release`, then run
`powershell -File tool/package_windows.ps1` (optional `-OutputDirectory <new-folder>`).
The script copies the release app, sibling ML scripts and weights, Python's standard
runtime and the ML virtualenv's dependencies into a new `dist/` folder. Keep that
folder together. Users need neither Python nor a model download. This Windows
packaging script does not produce a macOS installer; macOS signing/entitlements
remain separate packaging work.


## Suggested subject tags

Select images, choose **Edit tags**, then open **Suggestions**. Use **Suggest tags**
for the displayed image or **Suggest for all** for the selection. Review each image
with the arrows and check the labels you want. Nothing is assigned until **Apply tags**; Cancel discards all checks. Accepted labels apply only to their image and
create/reuse named tags. Manual batch additions/removals and accepted suggestions
are committed in one catalog transaction; explicit manual removals take priority.
The wizard also works when the library has no tags yet.

`TagSuggester` is a backend-neutral interface, separate from classification,
embedding and persistence. The default local SigLIP implementation ranks the
library's existing names plus `umbra-tags-ml/tag_vocabulary.json`. It returns up to
12 possible tags per image, with ranking scores (not calibrated probabilities).
Matching cached image vectors are reused; a different embedding model can coexist
with the tagger's own bundled image encoder. Suggestions are temporary review data;
only accepted assignments are saved. Batch generation can stop after the current
image, and individual failures do not discard other results.

The tagger adds the matching bundled SigLIP text encoder/tokenizer (~1.05 GiB).
No runtime downloads occur. Rebuild the offline package to include the updated ML
scripts, text model, tokenizer and SentencePiece dependency.


## Options

**Edit → Options…** opens Startup, Machine learning, and Browser extension tabs.
Startup has independent checkboxes for the selected artwork/photo classifier,
similarity image encoder and tag-suggestion text encoder, plus reopening the last
library. Save changes for the next launch, or use Save and load selected now.
Preloading does not change per-library indexing pause/resume. Unchecked models
still load when their features need them. The old all-model startup preference
migrates to the three individual checkboxes.

Machine learning contains the classifier choice, ML folder, Python override,
classification threshold and automatic assignment controls. Browser extension
can disable/enable the local receiver or change its port (1024–65535; default 8934).
Changing ports binds the replacement before closing the old server; a bind error
keeps the old connection running. Match the port under Connection settings in the
browser extension popup. Options are saved in the existing flutter-session.json.

## Windows installers and fast updates

Run these commands from the Flutter project directory. Inno Setup 6 and Flutter
must be installed; use `-FlutterCommand C:\src\flutter\bin\flutter.bat` if needed.

```powershell
# Routine release: build Flutter and package only app code/assets/backend scripts.
powershell -ExecutionPolicy Bypass -File tool/build_installer.ps1

# Reuse an already-built Release executable (only when it is up to date).
powershell -ExecutionPolicy Bypass -File tool/build_installer.ps1 -SkipBuild

# Occasional first-install/offline release, including Python and all model weights.
powershell -ExecutionPolicy Bypass -File tool/build_installer.ps1 -Mode Full

# Standalone ML pack: no Flutter build. Rebuild only when models/dependencies change.
powershell -ExecutionPolicy Bypass -File tool/build_installer.ps1 -Mode Runtime
```

Outputs go to separate timestamped `dist/installer-<Mode>-<timestamp>` directories.
App-only installers are single EXEs and do not copy, hash or compress model weights
or Python packages. `-BundleDirectory <existing-bundle>` reuses a prepared bundle.
No tests run in these scripts. `package_windows.ps1` still defaults to Full for
portable distribution and also accepts `-Mode App` or `-Mode Runtime`.

Existing full installations can immediately use app-only updates: their local ML
files remain installed, while backend scripts are updated. There is no required
redownload or migration. On a new machine, install the App installer and the Runtime
pack, or use Full. Without a compatible runtime, the app still manages libraries
and reports an actionable error when ML is requested.

The standalone runtime installs independently under
`%LOCALAPPDATA%\Umbra Tags\ML\<runtimeId>`, with its own uninstaller. The app
prefers a compatible local runtime, then the shared versioned pack. Code stays with
the app; only Python, dependencies, weights and licenses belong in the pack.
`runtime-requirements.json` in the ML source declares the required runtime ID;
`ml-runtime.json` identifies a packaged runtime. Bump the runtime ID when changing
weights or dependencies, build the new pack, then build the app update. Runtime IDs
are immutable compatibility versions; code-only changes do not need a new ID.
The original unmarked full bundle is accepted as baseline runtime 1. Model bundles
retain their existing integrity verification and embedding identities.
Explicit ML home/Python settings and environment overrides remain available.

The app keeps its Flutter AppId (`7040E4F7-ABCB-4FE7-AAD9-DC602B72EA63`), per-user
installation folder and separate shortcuts. WinForms is untouched. App uninstall
preserves external libraries, settings, and separately installed runtime packs.
These installers are unsigned; retain accompanying BIN files for Full/Runtime.

## Find images for a tag

Open a tag's three-dot menu and choose **Find matching images…**. The scan considers
all available, non-archived images in the current library that do not already have
that exact tag, regardless of the current gallery filter. It defaults to the configured
classifier when the tag name matches a label reported by that model (case-insensitive),
and otherwise uses the text/image tag suggestion backend. You can switch the source
and map any tag to an available classifier label explicitly.

The classifier uses its configured confidence cutoff; semantic matching starts at
rank score 0.15. These are separate cutoffs, not combined scores. Adjust the cutoff
for the tag and review ranked thumbnails before pressing **Add images to tag**.
Changing the cutoff reselects matches; individual checkboxes allow further review.
Stop finishes the current image, preserving partial results for review. Errors appear
per image, and scanning alone never assigns tags. Applying adds only the selected tag
in one catalog transaction with asset hash checks. Existing tags are preserved.
Semantic scoring reuses compatible stored image vectors and computes missing ones.
Deploy the updated Python tag_worker.py alongside the Flutter build; older installers
must be rebuilt to include this feature.

## AI refinement within a tag hierarchy

Right-click a tag in the left sidebar to open its existing management menu.
Select gallery images, then right-click an image and choose **AI refine tags…**.
The action appears when at least one available selected image has an explicitly
assigned tag with children. Each eligible image is compared with the direct children
of each of its assigned parent tags using the tag suggestion backend and cached
image embeddings. It does not recursively descend through new recommendations.
The review shows up to three ranked candidates per parent, preselecting the best
new child at or above the adjustable cutoff (initially 0.15). Already assigned
children remain visible, and existing parents/tags are preserved. You may select
additional candidates manually. Apply commits accepted additions together; Cancel
makes no tag changes. Missing images and images without qualifying parents are skipped.
