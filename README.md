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

Select images with click, Ctrl/Cmd-click, or marquee selection, then choose **Edit
tags** below the preview or **Edit → Edit tags…**. A dash means some selected images
have the tag. Changes apply to the whole selection; untouched assignments remain.

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

## Windows installer (side by side with WinForms)

Run `powershell -ExecutionPolicy Bypass -File tool/build_installer.ps1` with Flutter
on PATH and Inno Setup 6 installed. It builds the Windows release, creates the
complete offline Python/model bundle, then compiles the installer into a new
`dist/installer-<timestamp>` folder. No tests are run by this script.
Use `-FlutterCommand C:\src\flutter\bin\flutter.bat` or `-IsccPath <path>` as needed.
`-BundleDirectory <complete-package>` skips rebuilding/packaging; this must be a
current package including the Visual C++ runtime DLLs. Version comes from pubspec.yaml.
Keep the setup EXE and any accompanying BIN files together when distributing it.

The installer is named **Umbra Tags (Flutter)** and uses its own permanent AppId
(`7040E4F7-ABCB-4FE7-AAD9-DC602B72EA63`). It installs per user into
`%LOCALAPPDATA%\Programs\Umbra Tags Flutter`, with separate Start menu and optional
Desktop shortcuts. The window still says Umbra Tags. Later Flutter releases reuse
this AppId; never replace it with the WinForms AppId. Existing WinForms installation,
shortcuts, settings and libraries are not renamed, removed or converted.

Uninstall removes installed program files and its own shortcuts, not AppData
settings or external library folders. Keep libraries outside the application folder.
The package includes app-local Visual C++ runtime DLLs from Visual Studio's x64
redistributable directory, so setup does not require a .NET or Python installation.
This is an unsigned Windows installer; macOS packaging remains separate.

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
