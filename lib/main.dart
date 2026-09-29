import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;
import 'storage/library_store.dart';
import 'storage/tag_repository.dart';
import 'widgets/tag_widgets.dart';
import 'widgets/tag_match_dialog.dart';
import 'widgets/hierarchy_dialog.dart';
import 'receiver_server.dart';
import 'ml/classifier.dart';
import 'ml/image_embedder.dart';
import 'ml/tag_suggester.dart';
import 'ml/similarity_controller.dart';
import 'widgets/similarity_widgets.dart';
import 'widgets/ml_settings_dialog.dart';
import 'widgets/options_dialog.dart';
import 'widgets/preview_details.dart';
import 'widgets/gallery_drop_target.dart';
import 'widgets/downloads_import_dialog.dart';
import 'widgets/exact_masonry.dart';
import 'widgets/view_breadcrumbs.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setTitle('Umbra Tags');
  await windowManager.setMinimumSize(const Size(1024, 600));
  await windowManager.setPreventClose(true);
  runApp(const GalleryApp(startReceiver: true));
}

Future<File> _sessionFile() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory(p.join(base.path, 'Umbra Tags'));
  await dir.create(recursive: true);
  return File(p.join(dir.path, 'flutter-session.json'));
}

Future<Map<String, dynamic>> _loadSession([File? sessionFile]) async {
  try {
    final file = sessionFile ?? await _sessionFile();
    if (await file.exists()) {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    }
  } catch (_) {}
  return {};
}

Future<void> _saveSession(
  Map<String, dynamic> data, [
  File? sessionFile,
]) async {
  try {
    final file = sessionFile ?? await _sessionFile();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(data), flush: true);
    await temporary.rename(file.path);
  } catch (_) {}
}

abstract final class AppColors {
  static const darker = Color(0xFF171717);
  static const lighter = Color(0xFF262622);
  static const accent = Color(0xFFB5372D);
}

enum LayoutMode { crop, letterbox, masonry }

double _settingNumber(Object? value, double fallback, double min, double max) =>
    value is num && value.isFinite
    ? value.toDouble().clamp(min, max)
    : fallback;

class GalleryApp extends StatelessWidget {
  const GalleryApp({super.key, this.startReceiver = false, this.sessionFile});
  final bool startReceiver;
  final File? sessionFile;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Umbra Tags',
      theme: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: AppColors.accent,
          onPrimary: Colors.white,
          secondary: AppColors.accent,
          onSecondary: Colors.white,
          surface: AppColors.darker,
        ),
        scaffoldBackgroundColor: AppColors.lighter,
        // Match the side panels; Material 3 otherwise tints the bar with the
        // accent colour.
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.darker,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
        ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: AppColors.accent,
          thumbColor: AppColors.accent,
          overlayColor: Color(0x29B5372D),
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return AppColors.accent;
              }
              return null;
            }),
          ),
        ),
      ),
      home: AppShell(startReceiver: startReceiver, sessionFile: sessionFile),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AppShell extends StatelessWidget {
  const AppShell({super.key, this.startReceiver = false, this.sessionFile});
  final bool startReceiver;
  final File? sessionFile;
  @override
  Widget build(BuildContext context) =>
      GalleryPage(startReceiver: startReceiver, sessionFile: sessionFile);
}

class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key, this.startReceiver = false, this.sessionFile});
  final bool startReceiver;
  final File? sessionFile;

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> with WindowListener {
  double _tileSize = 200;
  LayoutMode _layout = LayoutMode.crop;
  double _committedWidth = 0;
  double _pendingWidth = 0;
  Timer? _resizeTimer;
  final Set<String> _selectedPaths = {};
  double _previewWidth = 300;
  bool _previewVisible = true;

  // Marquee selection state
  // Alt + left-drag draws a selection box (marquee).
  Offset? _dragStart;
  Offset? _dragCurrent;
  // A plain left-drag starting on a tile drags its files out to other apps.
  Offset? _fileDragOrigin;
  String? _fileDragPath;
  bool _draggingOut = false;
  // Ctrl/Cmd state when the button went down. Tiles also accept double-clicks,
  // so their tap callback runs only after the double-click window, by which
  // time a quick Ctrl-click has usually released the key.
  bool _toggleOnTap = false;
  // Shift at pointer down selects a range, in gallery order, from the anchor:
  // the image last clicked without Shift.
  bool _rangeOnTap = false;
  String? _selectionAnchor;
  static const _dragChannel = MethodChannel('umbra_tags/drag');
  final _gridKey = GlobalKey();
  final _scrollController = ScrollController();
  final _galleryFocus = FocusNode(debugLabel: 'Gallery');

  LibraryStore? _library;
  List<LibraryAsset> _assets = [];
  List<String> _imagePaths = [];
  final Map<String, LibraryAsset> _assetsByPath = {};
  final Map<String, GlobalKey> _tileKeys = {};
  final Map<String, Future<String?>> _thumbnails = {};
  bool _busy = false;
  Completer<void>? _operationIdle;
  Future<void>? _applyingOptions;
  bool _closeRequested = false;
  bool _closingWindow = false;
  bool _showArchived = false;
  bool _untagged = false;
  String? _tagFilter;
  List<LibraryTag> _tags = [];
  List<LibraryAsset> get _selection => _selectedPaths
      .map((path) => _assetsByPath[path])
      .whereType<LibraryAsset>()
      .toList();
  String _status = 'Create or open a library to begin';
  String? _lastLibraryPath;
  Timer? _sessionTimer;
  Future<void> _sessionWrite = Future.value();
  bool _sessionRestored = false;
  final Map<String, double> _scrollPositions = {};
  double? _pendingScrollOffset;
  String? get _scrollKey => _library == null
      ? null
      : '${_library!.id}/${_showArchived
            ? 'archive'
            : _untagged
            ? 'untagged'
            : _tagFilter != null
            ? 'tag/$_tagFilter'
            : 'all'}';

  void _rememberScrollPosition() {
    if (_pendingScrollOffset != null ||
        !_scrollController.hasClients ||
        _scrollKey == null) {
      return;
    }
    _scrollPositions[_scrollKey!] = _scrollController.offset;
    _persistSession();
  }

  void _queueScrollRestore() {
    _pendingScrollOffset = _scrollPositions[_scrollKey] ?? 0;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _restoreScrollPosition(),
    );
  }

  void _restoreScrollPosition() {
    if (!mounted ||
        _pendingScrollOffset == null ||
        !_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions) {
      return;
    }
    _scrollController.jumpTo(
      _pendingScrollOffset!.clamp(
        0,
        _scrollController.position.maxScrollExtent,
      ),
    );
    _pendingScrollOffset = null;
  }

  final Map<String, Map<String, String>> _knownLibraries = {};
  ReceiverServer? _receiver;
  String _receiverStatus = 'Web receiver starting';
  MlSettings _mlSettings = const MlSettings();
  final Set<String> _startupModels = {};
  bool _reopenLastLibrary = true;
  bool _receiverEnabled = true;
  int _receiverPort = kPort;
  bool _warmingModels = false;
  ImageEmbedder? _standbyEmbedder;
  final Map<String, String> _modelStartupStatus = {
    'Artwork / photo classifier': 'On demand',
    'Similarity image encoder': 'On demand / indexing',
    'Tag suggestion text encoder': 'On demand',
  };

  Future<void> _warmModels([Set<String>? selectedModels]) async {
    final selected = Set<String>.from(selectedModels ?? _startupModels);
    if (_warmingModels || !mounted || _closingWindow) return;
    setState(() => _warmingModels = true);
    final loaders = <String, Future<void> Function()>{
      'Artwork / photo classifier': () =>
          _imageClassifier.loadModel(_mlSettings.modelId),
      'Similarity image encoder': () async {
        final controller = _similarity;
        if (controller != null) {
          await controller.warmUp();
        } else {
          final embedder = _standbyEmbedder ??= PythonImageEmbedder(
            home: _mlSettings.home,
            python: _mlSettings.python,
          );
          await embedder.load();
        }
      },
      'Tag suggestion text encoder': () => _suggestionBackend.load(),
    };
    try {
      for (final entry in loaders.entries) {
        if (!selected.any((id) => startupModels[id] == entry.key)) continue;
        if (!mounted || _closingWindow) return;
        setState(() {
          _modelStartupStatus[entry.key] = 'Loading…';
          _status = 'Loading ${entry.key}…';
        });
        try {
          await entry.value();
          if (mounted && !_closingWindow) {
            setState(() => _modelStartupStatus[entry.key] = 'Loaded');
          }
        } catch (error) {
          if (mounted && !_closingWindow) {
            setState(() => _modelStartupStatus[entry.key] = 'Failed: $error');
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _warmingModels = false;
          final failures = selected
              .map((id) => _modelStartupStatus[startupModels[id]])
              .whereType<String>()
              .where((status) => status.startsWith('Failed:'))
              .toList();
          _status = failures.isEmpty
              ? 'Selected ML models loaded'
              : failures.first;
        });
      }
    }
  }

  ImageClassifier? _classifier;
  TagSuggester? _tagSuggester;
  TagSuggester get _suggestionBackend => _tagSuggester ??= PythonTagSuggester(
    home: _mlSettings.home,
    python: _mlSettings.python,
  );

  Future<List<TagSuggestion>> _suggestTags(
    LibraryAsset asset, {
    String? matchingTag,
    List<String>? candidateLabels,
  }) async {
    if (_closingWindow) throw StateError('Application is closing.');
    final library = _library!;
    final backend = _suggestionBackend;
    final similarity = _similarity;
    final candidates =
        candidateLabels ??
        (matchingTag == null
            ? _tags.map((tag) => tag.name).toList()
            : [matchingTag]);
    final model = await backend.info();
    if (!identical(library, _library)) throw StateError('Library changed.');
    List<double>? vector;
    String? key;
    if (similarity != null) {
      await similarity.start();
      if (model.compatibleEmbeddingKey != null &&
          similarity.model?.key == model.compatibleEmbeddingKey &&
          similarity.error == null) {
        await similarity.ensure(asset);
        key = model.compatibleEmbeddingKey;
        vector =
            (await library.similarity({
                      'op': 'vector',
                      'key': key,
                      'assetId': asset.id,
                    })
                    as List?)
                ?.cast<double>();
      }
    }
    return backend.suggest(
      asset: asset,
      imagePath: library.absolutePath(asset.relativePath),
      candidates: candidates,
      includeDefaults: matchingTag == null && candidateLabels == null,
      embeddingKey: key,
      vector: vector,
    );
  }

  SimilarityController? _similarity;

  Future<void> _stopSimilarity() async {
    final controller = _similarity;
    _similarity = null;
    if (controller != null) {
      await controller.stop();
      controller.dispose();
    }
  }

  void _startSimilarity() {
    if (_closingWindow) return;
    if (_library == null) return;
    final embedder =
        _standbyEmbedder ??
        PythonImageEmbedder(home: _mlSettings.home, python: _mlSettings.python);
    _standbyEmbedder = null;
    final controller = SimilarityController(
      _library!,
      embedder,
      shouldYield: () => _busy || _closingWindow,
    );
    _similarity = controller;
    unawaited(controller.start());
  }

  void _findSimilar(LibraryAsset asset) {
    final controller = _similarity;
    if (_busy || controller == null) return;
    showDialog<void>(
      context: context,
      builder: (_) => SimilarityDialog(
        controller: controller,
        source: asset,
        onOpen: _openAssetExternally,
      ),
    );
  }

  bool _classifying = false;
  bool _cancelClassification = false;

  ImageClassifier get _imageClassifier => _classifier ??= PythonImageClassifier(
    home: _mlSettings.home,
    python: _mlSettings.python,
  );

  void _configureOptions() => _run(() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => OptionsDialog(
        options: AppOptions(
          ml: _mlSettings,
          preloadModels: Set.of(_startupModels),
          reopenLastLibrary: _reopenLastLibrary,
          receiverEnabled: _receiverEnabled,
          receiverPort: _receiverPort,
        ),
        receiverStatus: _receiverStatus,
        modelStatus: Map.of(_modelStartupStatus),
        onSave: _applyOptions,
      ),
    );
  });

  Future<void> _applyOptions(AppOptions options, bool loadNow) {
    if (_closingWindow) return Future.value();
    return _applyingOptions ??= _applyOptionsNow(
      options,
      loadNow,
    ).whenComplete(() => _applyingOptions = null);
  }

  Future<void> _applyOptionsNow(AppOptions options, bool loadNow) async {
    // Bind a replacement before closing the current receiver so an occupied
    // port leaves the working connection and saved options intact.
    final restartReceiver =
        options.receiverEnabled != _receiverEnabled ||
        options.receiverPort != _receiverPort ||
        (options.receiverEnabled && _receiver?.port == null);
    if (restartReceiver && widget.startReceiver) {
      ReceiverServer? replacement;
      if (options.receiverEnabled) {
        replacement = _createWebReceiver();
        try {
          await replacement.start(port: options.receiverPort);
        } catch (_) {
          await replacement.close();
          rethrow;
        }
      }
      await _receiver?.close();
      if (_closingWindow) {
        await replacement?.close();
        return;
      }
      _receiver = replacement;
      _receiverStatus = replacement == null
          ? 'Browser extension connection disabled'
          : 'Web receiver ready · localhost:${options.receiverPort}';
    }
    final runtimeChanged =
        options.ml.home != _mlSettings.home ||
        options.ml.python != _mlSettings.python ||
        options.ml.modelId != _mlSettings.modelId;
    if (runtimeChanged) {
      await _standbyEmbedder?.dispose();
      _standbyEmbedder = null;
      await _tagSuggester?.dispose();
      _tagSuggester = null;
      await _classifier?.dispose();
      _classifier = null;
      await _stopSimilarity();
      _modelStartupStatus.updateAll((key, value) => 'On demand');
    }
    if (_closingWindow || !mounted) return;
    setState(() {
      _mlSettings = options.ml;
      _startupModels
        ..clear()
        ..addAll(options.preloadModels);
      _reopenLastLibrary = options.reopenLastLibrary;
      _receiverEnabled = options.receiverEnabled;
      _receiverPort = options.receiverPort;
    });
    if (runtimeChanged) _startSimilarity();
    _writeSession();
    await _sessionWrite;
    if (loadNow) unawaited(_warmModels(Set.of(_startupModels)));
  }

  void _classifySelection() => _run(() async {
    final selected = _selection;
    final library = _library;
    if (selected.isEmpty || library == null) return;
    _cancelClassification = false;
    setState(() {
      _classifying = true;
      _status = 'Loading ML classifier…';
    });
    final details = <({String filename, String result})>[];
    var tagged = 0, predicted = 0, failed = 0;
    try {
      final classifier = _imageClassifier;
      await classifier.loadModel(_mlSettings.modelId);
      for (var index = 0; index < selected.length; index++) {
        if (_cancelClassification || !mounted) break;
        final asset = selected[index];
        setState(
          () => _status =
              'ML classify ${index + 1} of ${selected.length}: ${asset.originalFilename}',
        );
        try {
          final result = await classifier.classify(
            assetId: asset.id,
            imagePath: library.absolutePath(asset.relativePath),
            contentHash: asset.contentHash,
            modelId: _mlSettings.modelId,
          );
          if (result.assetId != asset.id ||
              result.contentHash != asset.contentHash) {
            throw StateError(
              'Classifier returned a result for a different image.',
            );
          }
          final tags = await library.applyClassification(
            assetId: result.assetId,
            contentHash: result.contentHash,
            modelId: result.modelId,
            modelVersion: result.modelVersion,
            scores: result.scores,
            threshold: _mlSettings.threshold,
            assignTags: _mlSettings.assignTags,
          );
          predicted++;
          if (tags.isNotEmpty) tagged++;
          final scores = result.scores.toList()
            ..sort(
              (a, b) =>
                  (b['confidence'] as num).compareTo(a['confidence'] as num),
            );
          final best = scores.first;
          details.add((
            filename: asset.originalFilename,
            result:
                '${best['label']} · ${((best['confidence'] as num) * 100).toStringAsFixed(1)}% · ${tags.isEmpty ? 'prediction saved; no tag added' : 'tag assigned'}',
          ));
        } catch (error) {
          failed++;
          details.add((
            filename: asset.originalFilename,
            result: error.toString(),
          ));
        }
      }
    } finally {
      if (mounted) setState(() => _classifying = false);
      await _reload();
    }
    if (!mounted) return;
    final summary =
        '$predicted classified · $tagged tagged · $failed failed${_cancelClassification ? ' · stopped' : ''}';
    setState(() => _status = summary);
    if (_closeRequested) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ML classification'),
        content: SizedBox(
          width: 580,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(summary),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: details.length,
                  itemBuilder: (_, index) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      details[index].filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(details[index].result),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  });

  Future<T> _withWebLibrary<T>(
    String id,
    Future<T> Function(LibraryStore) operation,
  ) async {
    if (_busy || _closingWindow || !mounted) {
      throw ReceiverException(409, 'Umbra Tags is busy. Try again shortly.');
    }
    final entry = _knownLibraries[id];
    if (entry == null) {
      throw ReceiverException(404, 'Open this library in Umbra Tags first.');
    }
    _operationIdle = Completer<void>();
    setState(() => _busy = true);
    LibraryStore? store;
    try {
      store = _library?.id == id
          ? _library!
          : await LibraryStore.open(entry['path']!);
      if (store.id != id) {
        throw ReceiverException(
          409,
          'The library at this location has changed. Open it again in Umbra Tags.',
        );
      }
      return await operation(store);
    } finally {
      try {
        if (store != null && !identical(store, _library)) await store.close();
      } finally {
        if (mounted) setState(() => _busy = false);
        _operationIdle?.complete();
        _operationIdle = null;
      }
    }
  }

  ReceiverServer _createWebReceiver() => ReceiverServer(
    libraries: () async => _knownLibraries.entries
        .map(
          (entry) => <String, Object?>{
            'id': entry.key,
            'name': entry.value['name'],
            'active': entry.key == _library?.id,
          },
        )
        .toList(),
    tags: (id) => _withWebLibrary(
      id,
      (store) async => (await store.tags())
          .map(
            (tag) => <String, Object?>{
              'id': tag.id,
              'name': tag.name,
              'parentId': tag.parentId,
            },
          )
          .toList(),
    ),
    capture: (capture) => _withWebLibrary(capture.libraryId, (store) async {
      final current = identical(store, _library);
      final result = await store.importCapture(
        capture.bytes,
        filename: capture.filename,
        // Like disk imports, captures into the open library join its tag view.
        tagIds: {
          ...capture.tagIds,
          if (current && _tagFilter != null) _tagFilter!,
        }.toList(),
        maxDimension: capture.maxDimension,
      );
      if (current) {
        await _reload();
        _showNewestImports();
      }
      if (mounted) {
        setState(
          () => _status =
              '${result.duplicate ? 'Already in' : 'Received in'} ${store.name}: ${result.asset.originalFilename}',
        );
      }
      return <String, Object?>{
        'assetId': result.asset.id,
        'duplicate': result.duplicate,
        'libraryName': store.name,
        'width': result.asset.width,
        'height': result.asset.height,
      };
    }),
  );
  Future<void> _startWebReceiver() async {
    if (!widget.startReceiver || !mounted || _closingWindow) return;
    if (!_receiverEnabled) {
      setState(() => _receiverStatus = 'Browser extension connection disabled');
      return;
    }
    final receiver = _createWebReceiver();
    _receiver = receiver;
    try {
      await receiver.start(port: _receiverPort);
      if (!mounted || _closingWindow) {
        await receiver.close();
        return;
      }
      setState(
        () => _receiverStatus = 'Web receiver ready · localhost:$_receiverPort',
      );
    } catch (error) {
      if (mounted) {
        setState(() => _receiverStatus = 'Web receiver unavailable: $error');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _scrollController.addListener(_rememberScrollPosition);
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final data = await _loadSession(widget.sessionFile);
    if (!mounted) return;
    setState(() {
      _tileSize = _settingNumber(data['tileSize'], 200, 50, 400);
      _previewWidth = _settingNumber(data['previewWidth'], 300, 150, 800);
      _layout =
          LayoutMode.values
              .where((value) => value.name == data['layout'])
              .firstOrNull ??
          LayoutMode.crop;
      _previewVisible = data['previewVisible'] is bool
          ? data['previewVisible'] as bool
          : true;
      _lastLibraryPath = data['lastLibraryPath'] is String
          ? data['lastLibraryPath'] as String
          : null;
      if (data['scrollPositions'] is Map) {
        for (final entry in (data['scrollPositions'] as Map).entries) {
          if (entry.key is String && entry.value is num) {
            _scrollPositions[entry.key as String] = _settingNumber(
              entry.value,
              0,
              0,
              1e9,
            );
          }
        }
      }
      final startup = data['startupModels'];
      _startupModels.clear();
      if (startup is List) {
        _startupModels.addAll(
          startup.whereType<String>().where(startupModels.containsKey),
        );
      } else if (data['preloadMlOnLaunch'] == true) {
        _startupModels.addAll(startupModels.keys);
      }
      _reopenLastLibrary = data['reopenLastLibrary'] != false;
      _receiverEnabled = data['receiverEnabled'] != false;
      final port = data['receiverPort'];
      _receiverPort = port is int && port >= 1024 && port <= 65535
          ? port
          : kPort;
      _sessionRestored = true;
      final ml = data['ml'];
      if (ml is Map) {
        _mlSettings = MlSettings(
          home: ml['home'] is String ? ml['home'] as String : null,
          python: ml['python'] is String ? ml['python'] as String : null,
          modelId: ml['modelId'] is String ? ml['modelId'] as String : null,
          threshold: _settingNumber(ml['threshold'], 0.8, 0, 1),
          assignTags: ml['assignTags'] != false,
        );
      }
      if (!Platform.isMacOS && data['webLibraries'] is List) {
        for (final entry in data['webLibraries'] as List) {
          if (entry is Map &&
              entry['id'] is String &&
              entry['name'] is String &&
              entry['path'] is String) {
            _knownLibraries[entry['id'] as String] = {
              'name': entry['name'] as String,
              'path': entry['path'] as String,
            };
          }
        }
      }
    });
    // A sandboxed Mac must reselect the folder to grant access for this session.
    if (_reopenLastLibrary &&
        !Platform.isMacOS &&
        _lastLibraryPath != null &&
        !_busy &&
        _library == null) {
      await _run(() async {
        await _attach(await LibraryStore.open(_lastLibraryPath!));
      });
    }
    await _startWebReceiver();
    if (_startupModels.isNotEmpty && mounted && !_closingWindow) {
      unawaited(_warmModels());
    }
  }

  void _persistSession() {
    if (!_sessionRestored || _closingWindow) return;
    _sessionTimer?.cancel();
    _sessionTimer = Timer(const Duration(milliseconds: 350), _writeSession);
  }

  void _writeSession() {
    if (!_sessionRestored) return;
    final data = <String, dynamic>{
      'startupModels': _startupModels.toList(),
      'reopenLastLibrary': _reopenLastLibrary,
      'receiverEnabled': _receiverEnabled,
      'receiverPort': _receiverPort,
      'tileSize': _tileSize,
      'previewWidth': _previewWidth,
      'layout': _layout.name,
      'ml': {
        'home': _mlSettings.home,
        'python': _mlSettings.python,
        'modelId': _mlSettings.modelId,
        'threshold': _mlSettings.threshold,
        'assignTags': _mlSettings.assignTags,
      },
      'previewVisible': _previewVisible,
      'scrollPositions': Map<String, double>.from(_scrollPositions),
      'lastLibraryPath': _lastLibraryPath,
      'webLibraries': _knownLibraries.entries
          .map((entry) => {'id': entry.key, ...entry.value})
          .toList(),
    };
    final sessionFile = widget.sessionFile;
    _sessionWrite = _sessionWrite.then((_) => _saveSession(data, sessionFile));
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy || _closingWindow) return;
    _operationIdle = Completer<void>();
    setState(() => _busy = true);
    try {
      await operation();
    } catch (error) {
      if (mounted && !_closingWindow) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Library operation could not finish'),
            content: SelectableText(error.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      _operationIdle?.complete();
      _operationIdle = null;
    }
  }

  Future<void> _attach(LibraryStore library) async {
    if (!mounted || _closingWindow) {
      await library.close();
      return;
    }
    _rememberScrollPosition();
    await _stopSimilarity();
    await _library?.close();
    if (_closingWindow || !mounted) {
      await library.close();
      return;
    }
    _library = library;
    _startSimilarity();
    _lastLibraryPath = library.root;
    _knownLibraries[library.id] = {'name': library.name, 'path': library.root};
    _showArchived = false;
    _untagged = false;
    _tagFilter = null;
    _thumbnails.clear();
    await _reload();
    _queueScrollRestore();
    _persistSession();
  }

  Future<void> _reload() async {
    if (_closingWindow) return;
    final tags = await _library!.tags();
    if (_tagFilter != null && !tags.any((tag) => tag.id == _tagFilter)) {
      _tagFilter = null;
    }
    final assets = await _library!.assets(
      archived: _showArchived,
      untagged: _untagged,
      tagId: _tagFilter,
      excludeHidden: !_showArchived && !_untagged,
    );
    if (!mounted) return;
    setState(() {
      _assets = assets;
      _tags = tags;
      _imagePaths = assets
          .map((a) => _library!.absolutePath(a.relativePath))
          .toList();
      _assetsByPath.clear();
      for (var i = 0; i < assets.length; i++) {
        _assetsByPath[_imagePaths[i]] = assets[i];
      }
      _tileKeys.removeWhere((key, _) => !_assetsByPath.containsKey(key));
      for (final path in _imagePaths) {
        _tileKeys.putIfAbsent(path, () => GlobalKey());
      }
      _selectedPaths.removeWhere((path) => !_assetsByPath.containsKey(path));
      _status =
          '${assets.length} images${_showArchived ? ' archived' : ''}'
          '${assets.any((a) => a.missing) ? ' · ${assets.where((a) => a.missing).length} missing' : ''}';
    });
  }

  /// A tag dropped on a selected image applies to the whole selection;
  /// dropped on any other image, to just that one.
  void _applyDroppedTag(String path, LibraryTag tag) => _run(() async {
    final paths = _selectedPaths.contains(path) ? _selectedPaths : {path};
    final ids = [
      for (final target in paths)
        if (_assetsByPath[target] case final asset?) asset.id,
    ];
    if (ids.isEmpty) return;
    await _library!.editTags(ids, add: [tag.id], remove: const []);
    await _reload();
    if (mounted) {
      setState(
        () => _status =
            'Tagged ${ids.length} ${ids.length == 1 ? 'image' : 'images'} '
            '“${tag.name}”',
      );
    }
  });

  /// Scrolls to the top, where the newest imports are listed, optionally
  /// selecting them.
  void _showNewestImports({Set<String>? select}) {
    if (!mounted) return;
    if (select != null && select.isNotEmpty) {
      setState(
        () => _selectedPaths
          ..clear()
          ..addAll(select),
      );
    }
    _pendingScrollOffset = null;
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  Future<String?> _thumbnailFor(String path) {
    if (_thumbnails.length > 256) _thumbnails.remove(_thumbnails.keys.first);
    return _thumbnails.putIfAbsent(
      path,
      () => _library!.thumbnail(_assetsByPath[path]!),
    );
  }

  void _createLibrary() => _run(() async {
    final folder = await getDirectoryPath(
      confirmButtonText: 'Use empty folder',
    );
    if (folder == null || !mounted || _closingWindow) return;
    final input = TextEditingController(text: p.basename(folder));
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New library'),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Library name'),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (input.text.trim().isNotEmpty) {
                Navigator.pop(context, input.text);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    // Wait until the closing dialog has detached its editable text.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    input.dispose();
    if (name != null && !_closingWindow) {
      await _attach(await LibraryStore.create(folder, name));
    }
  });

  void _openLibrary() => _run(() async {
    final folder = await getDirectoryPath(
      initialDirectory: _lastLibraryPath,
      confirmButtonText: 'Open library',
    );
    if (folder != null && !_closingWindow) {
      await _attach(await LibraryStore.open(folder));
    }
  });

  void _closeLibrary() => _run(() async {
    _rememberScrollPosition();
    await _stopSimilarity();
    await _library?.close();
    if (!mounted) return;
    setState(() {
      _library = null;
      _tags = [];
      _tagFilter = null;
      _untagged = false;
      _assets = [];
      _imagePaths = [];
      _assetsByPath.clear();
      _tileKeys.clear();
      _selectedPaths.clear();
      _thumbnails.clear();
      _status = 'Library closed';
    });
  });

  void _importImages() => _run(() async {
    final library = _library;
    if (library == null) return;
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: LibraryStore.supportedExtensions,
          uniformTypeIdentifiers: ['public.image'],
        ),
      ],
    );
    await _importImageFiles(files);
  });

  void _importFromDownloads() => _run(() async {
    if (_library == null) return;
    final folder = (await getDownloadsDirectory())?.path;
    if (folder == null) {
      throw LibraryException('Could not find the Downloads folder.');
    }
    final files = <File>[];
    await for (final entity in Directory(folder).list(followLinks: false)) {
      final extension = p.extension(entity.path).toLowerCase();
      if (entity is File &&
          LibraryStore.supportedExtensions.contains(
            extension.replaceFirst('.', ''),
          )) {
        files.add(entity);
      }
    }
    if (files.isEmpty) {
      if (mounted) setState(() => _status = 'No images found in Downloads');
      return;
    }
    final modified = await Future.wait(
      files.map((file) => file.lastModified()),
    );
    final order = {
      for (var i = 0; i < files.length; i++) files[i].path: modified[i],
    };
    files.sort((a, b) => order[b.path]!.compareTo(order[a.path]!));
    if (!mounted) return;
    final chosen = await showDialog<List<String>>(
      context: context,
      builder: (_) => DownloadsImportDialog(
        folder: folder,
        files: files,
        accent: AppColors.accent,
        onOpen: (path) => unawaited(
          _shellChannel
              .invokeMethod<bool>('openFile', path)
              .catchError((_) => null),
        ),
      ),
    );
    if (chosen == null || chosen.isEmpty) return;
    await _importImageFiles([for (final path in chosen) XFile(path)]);
  });

  // Once imported (or found already in the library), source files move to the
  // Recycle Bin. Files inside the library folder are never touched.
  //
  // Imports land in the gallery that is open: a tag view assigns its tag so
  // they appear there, and the archive view switches to all images. The
  // gallery then scrolls to the top with the imported images selected.
  Future<void> _importImageFiles(List<XFile> files) async {
    final library = _library;
    if (library == null || files.isEmpty) return;
    final tagIds = [?_tagFilter];
    final imported = <String>{};
    var added = 0;
    var duplicates = 0;
    final errors = <String>[];
    final sources = <String>[];
    for (var i = 0; i < files.length; i++) {
      if (_closingWindow) break;
      if (mounted) {
        setState(() => _status = 'Importing ${i + 1} of ${files.length}…');
      }
      try {
        final result = await library.importImage(files[i].path, tagIds: tagIds);
        imported.add(library.absolutePath(result.asset.relativePath));
        final source = p.absolute(files[i].path);
        if (!p.isWithin(library.root, source) &&
            !p.equals(library.root, source)) {
          sources.add(source);
        }
        if (result.duplicate) {
          duplicates++;
        } else {
          added++;
        }
      } catch (error) {
        errors.add('${files[i].name}: $error');
      }
    }
    var recycled = 0;
    if (sources.isNotEmpty) {
      try {
        await _shellChannel.invokeMethod<bool>('recycleFiles', sources);
        recycled = sources.length;
      } on MissingPluginException {
        // Only the Windows runner provides this; elsewhere originals stay put.
      } on PlatformException catch (error) {
        errors.add(
          'Imported, but the originals were not moved to the Recycle Bin: '
          '${error.message}',
        );
      }
    }
    _thumbnails.clear();
    if (imported.isNotEmpty && _showArchived) _showArchived = false;
    await _reload();
    if (imported.isNotEmpty) {
      _showNewestImports(
        select: imported.where(_assetsByPath.containsKey).toSet(),
      );
    }
    if (mounted) {
      setState(
        () => _status =
            '$added imported · $duplicates already in library'
            '${recycled > 0 ? ' · $recycled originals moved to Recycle Bin' : ''}'
            '${errors.isNotEmpty ? ' · ${errors.length} failed' : ''}',
      );
    }
    if (errors.isNotEmpty) throw LibraryException(errors.join('\n'));
  }

  void _setFilter(LibraryView view, [String? tag]) => _run(() async {
    _rememberScrollPosition();
    _showArchived = view == LibraryView.archived;
    _untagged = view == LibraryView.untagged;
    _tagFilter = tag;
    _selectedPaths.clear();
    await _reload();
    _queueScrollRestore();
  });

  void _editTag({LibraryTag? tag, String? parent}) => _run(() async {
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TagDetailsDialog(
        tags: _tags,
        tag: tag,
        parentId: parent,
        onSave: (name, parentId) async {
          await _library!.saveTag(id: tag?.id, name: name, parentId: parentId);
        },
      ),
    );
    await _reload();
  });

  void _deleteTag(LibraryTag tag) => _run(() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete “${tag.name}”?'),
        content: const Text(
          'This removes the tag from all images. Child tags move up one level. Images are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete tag'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _library!.deleteTag(tag.id);
      await _reload();
    }
  });

  void _editSelectionTags() => _run(() async {
    final selected = _selection;
    if (selected.isEmpty) return;
    if (!mounted) return;
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BatchTagsDialog(
        tags: _tags,
        assets: selected,
        onSuggest: _suggestTags,
        thumbnail: (asset) => _library!.thumbnail(asset),
        onApplyReviewed: (add, remove, accepted) =>
            _library!.applyReviewedTags(selected, add, remove, accepted),
        onSave: (add, remove) => _library!.editTags(
          selected.map((a) => a.id).toList(),
          add: add,
          remove: remove,
        ),
      ),
    );
    await _reload();
  });

  bool _canRefineSelection() => _selection.any(
    (asset) =>
        !asset.missing &&
        _tags.any((tag) => asset.tagIds.contains(tag.parentId)),
  );

  void _refineSelection() => _run(() async {
    final library = _library;
    if (library == null || _closingWindow) return;
    final selected = _selection.toList();
    final tags = List<LibraryTag>.of(_tags);
    final children = <String, List<LibraryTag>>{};
    for (final tag in tags) {
      if (tag.parentId != null) {
        children.putIfAbsent(tag.parentId!, () => []).add(tag);
      }
    }
    final eligible = selected
        .where(
          (asset) => !asset.missing && asset.tagIds.any(children.containsKey),
        )
        .toList();
    if (eligible.isEmpty) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => HierarchyDialog(
        assets: eligible,
        skipped: selected.length - eligible.length,
        thumbnail: library.thumbnail,
        find: (asset) async {
          final matches = <HierarchyMatch>[];
          for (final parent in tags.where(
            (tag) =>
                asset.tagIds.contains(tag.id) && children.containsKey(tag.id),
          )) {
            final candidates = children[parent.id]!;
            final scores = <TagSuggestion>[];
            // The generic suggestion protocol accepts at most 512 candidates.
            for (var offset = 0; offset < candidates.length; offset += 512) {
              if (_closingWindow || !identical(library, _library)) {
                throw StateError('Library closed.');
              }
              scores.addAll(
                await _suggestTags(
                  asset,
                  candidateLabels: candidates
                      .skip(offset)
                      .take(512)
                      .map((tag) => tag.name)
                      .toList(),
                ),
              );
            }
            final byName = {
              for (final child in candidates) child.name.toLowerCase(): child,
            };
            final ranked =
                scores
                    .where(
                      (score) => byName.containsKey(score.label.toLowerCase()),
                    )
                    .toList()
                  ..sort((a, b) => b.score.compareTo(a.score));
            for (var i = 0; i < ranked.length && i < 3; i++) {
              final score = ranked[i];
              matches.add(
                HierarchyMatch(
                  asset,
                  parent,
                  byName[score.label.toLowerCase()]!,
                  score.score,
                  i == 0,
                ),
              );
            }
          }
          return matches;
        },
        apply: (accepted) async {
          if (_closingWindow || !identical(library, _library)) {
            throw StateError('Library closed.');
          }
          await library.applyReviewedTags(
            eligible.where((asset) => accepted.containsKey(asset.id)).toList(),
            [],
            [],
            accepted,
          );
        },
      ),
    );
    await _reload();
  });

  void _toggleTagExcluded(LibraryTag tag) => _run(() async {
    await _library!.setTagExcludedFromAll(tag.id, !tag.excludedFromAll);
    await _reload();
    if (mounted) {
      setState(
        () => _status = tag.excludedFromAll
            ? '“${tag.name}” images are shown in All images again'
            : '“${tag.name}” images are hidden from All images',
      );
    }
  });

  void _findTagMatches(LibraryTag tag) => _run(() async {
    final library = _library;
    if (library == null) return;
    final assets = (await library.assets())
        .where((asset) => !asset.missing && !asset.tagIds.contains(tag.id))
        .toList();
    if (_closingWindow) return;
    final classifier = _imageClassifier;
    final modelId = _mlSettings.modelId;
    List<String> labels = [];
    String? classifierError;
    try {
      labels = (await classifier.labels(modelId)).toSet().toList();
    } catch (error) {
      classifierError = error.toString();
    }
    if (!mounted || _closingWindow || !identical(library, _library)) return;
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TagMatchDialog(
        tagName: tag.name,
        assets: assets,
        classifierLabels: labels,
        classifierError: classifierError,
        classifierThreshold: _mlSettings.threshold,
        thumbnail: library.thumbnail,
        score: (asset, source, label) async {
          if (_closingWindow) throw StateError('Application is closing.');
          if (!identical(library, _library)) {
            throw StateError('Library changed.');
          }
          if (source == TagMatchSource.semantic) {
            final suggestions = await _suggestTags(asset, matchingTag: label);
            return suggestions
                .firstWhere(
                  (suggestion) =>
                      suggestion.label.toLowerCase() == label.toLowerCase(),
                  orElse: () => throw StateError(
                    'The model did not return a score for this tag.',
                  ),
                )
                .score;
          }
          final result = await classifier.classify(
            assetId: asset.id,
            imagePath: library.absolutePath(asset.relativePath),
            contentHash: asset.contentHash,
            modelId: modelId,
          );
          if (result.assetId != asset.id ||
              result.contentHash != asset.contentHash) {
            throw StateError('Classifier result does not match this image.');
          }
          final row = result.scores.firstWhere(
            (row) => row['label'] == label,
            orElse: () =>
                throw StateError('The classifier does not support this label.'),
          );
          return (row['confidence'] as num).toDouble();
        },
        onApply: (selected) async {
          if (!identical(library, _library)) {
            throw StateError('Library changed.');
          }
          await library.applyReviewedTags(selected, [tag.id], [], {});
        },
      ),
    );
    await _reload();
  });

  void _selectImage(String path) {
    if (_busy) return;
    _galleryFocus.requestFocus();
    setState(() {
      final from = _selectionAnchor == null
          ? -1
          : _imagePaths.indexOf(_selectionAnchor!);
      final to = _imagePaths.indexOf(path);
      if (_rangeOnTap && from >= 0 && to >= 0) {
        // Ctrl+Shift adds the range to the selection; Shift alone replaces it.
        if (!_toggleOnTap) _selectedPaths.clear();
        _selectedPaths.addAll(
          _imagePaths.sublist(
            from < to ? from : to,
            (from < to ? to : from) + 1,
          ),
        );
        return;
      }
      _selectionAnchor = path;
      if (_toggleOnTap) {
        if (!_selectedPaths.add(path)) _selectedPaths.remove(path);
      } else {
        _selectedPaths
          ..clear()
          ..add(path);
      }
    });
  }

  void _selectContextImage(String path) {
    if (_busy) return;
    _galleryFocus.requestFocus();
    if (!_selectedPaths.contains(path)) {
      _selectionAnchor = path;
      setState(
        () => _selectedPaths
          ..clear()
          ..add(path),
      );
    }
  }

  void _deleteSelection() => _run(() async {
    final selected = _selection;
    if (selected.isEmpty || _library == null) return;
    if (selected.length > 1) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Delete ${selected.length} images?'),
          content: const Text(
            'Permanently delete these images and their tag assignments from this library. Original files outside the library are kept. This cannot be undone.',
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete images'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    final ids = selected.map((asset) => asset.id).toSet();
    // Detach file-backed images before deletion: Windows can retain their file
    // mappings until the preview, thumbnail and cached codec are disposed.
    setState(() {
      _selectedPaths.clear();
      _assets.removeWhere((asset) => ids.contains(asset.id));
      _imagePaths.removeWhere((path) => ids.contains(_assetsByPath[path]?.id));
    });
    await WidgetsBinding.instance.endOfFrame;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    try {
      await _library!.deleteAssets(ids.toList());
    } finally {
      _thumbnails.clear();
      await _reload();
    }
    if (mounted) {
      setState(
        () => _status =
            '${selected.length} ${selected.length == 1 ? 'image' : 'images'} deleted',
      );
      _galleryFocus.requestFocus();
    }
  });
  void _openPreviewExternally() {
    if (_selectedPaths.isNotEmpty) _openImageExternally(_selectedPaths.first);
  }

  void _openImageExternally(String path) {
    final asset = _assetsByPath[path];
    if (asset != null) _openAssetExternally(asset);
  }

  // Opens via the runner's own channel rather than url_launcher, which calls
  // ShellExecute on the UI thread: Windows can take seconds to load its shell
  // components the first time, freezing the whole window meanwhile.
  static const _shellChannel = MethodChannel('umbra_tags/shell');

  void _openAssetExternally(LibraryAsset asset) => _run(() async {
    if (_library == null) return;
    final file = File(_library!.absolutePath(asset.relativePath));
    if (!await file.exists()) {
      throw LibraryException('This image file is missing from the library.');
    }
    if (await _shellChannel.invokeMethod<bool>('openFile', file.path) != true) {
      throw LibraryException(
        'Could not open this image. Choose a default app for its file type in your system settings.',
      );
    }
  });

  static const _clipboardChannel = MethodChannel('umbra_tags/clipboard');

  void _copyImageToClipboard(String path) => _run(() async {
    final asset = _assetsByPath[path];
    if (asset == null || _library == null) return;
    final file = File(_library!.absolutePath(asset.relativePath));
    if (!await file.exists()) {
      throw LibraryException('This image file is missing from the library.');
    }
    // The native side decodes with GDI+, which has no WebP codec.
    if (p.extension(file.path).toLowerCase() != '.webp') {
      await _clipboardChannel.invokeMethod<void>('copyImage', file.path);
      return;
    }
    final source = file.path;
    final png = await Isolate.run(() {
      final decoded = img.decodeImage(File(source).readAsBytesSync());
      return decoded == null ? null : img.encodePng(decoded);
    });
    if (png == null) throw LibraryException('Could not decode this image.');
    final temp = File(
      p.join(Directory.systemTemp.path, 'umbra-tags-clipboard.png'),
    );
    await temp.writeAsBytes(png, flush: true);
    await _clipboardChannel.invokeMethod<void>('copyImage', temp.path);
  });

  void _archiveSelection() => _run(() async {
    await _library!.archive(
      _selectedPaths.map((path) => _assetsByPath[path]!.id).toList(),
      !_showArchived,
    );
    await _reload();
  });

  void _refreshLibrary() => _run(() async {
    await _library!.refresh();
    _thumbnails.clear();
    await _reload();
  });

  void _backupLibrary() => _run(() async {
    final backup = await _library!.backup();
    if (mounted) {
      setState(() => _status = 'Metadata backup saved: ${p.basename(backup)}');
    }
  });

  @override
  void onWindowClose() async {
    if (_closingWindow) return;
    _closeRequested = true;
    _cancelClassification = true;
    setState(() {
      _closingWindow = true;
      _status = 'Closing…';
    });
    final timer = Stopwatch()..start();
    final timings = <String>['Shutdown ${DateTime.now().toIso8601String()}'];
    Future<void> step(String name, Future<void> Function() action) async {
      final stage = Stopwatch()..start();
      try {
        await action();
      } catch (error) {
        timings.add('$name failed: $error');
        debugPrint('Shutdown $name failed: $error');
      } finally {
        timings.add('$name: ${stage.elapsedMilliseconds} ms');
        debugPrint('Shutdown $name: ${stage.elapsedMilliseconds} ms');
      }
    }

    _rememberScrollPosition();
    _resizeTimer?.cancel();
    _sessionTimer?.cancel();
    _library?.cancelBackgroundWork();
    // Dismiss review/configuration dialogs so _run can finish. In-flight
    // catalog transactions still complete before the library is closed.
    Navigator.of(context).popUntil((route) => route.isFirst);
    _writeSession();
    final operationIdle = _operationIdle?.future;
    await Future.wait([
      step('settings', () => _sessionWrite),
      step('receiver', () async {
        await _receiver?.close();
      }),
      step('standby model', () async {
        await _standbyEmbedder?.dispose();
      }),
      step('tag model', () async {
        await _tagSuggester?.dispose();
      }),
      step('classifier', () async {
        await _classifier?.dispose();
      }),
      step('similarity', _stopSimilarity),
      step('active operation', () async {
        await operationIdle;
      }),
      step('options save', () async {
        await _applyingOptions;
      }),
    ]);
    _standbyEmbedder = null;
    _tagSuggester = null;
    _classifier = null;
    await step('library', () async {
      await _library?.close();
    });
    await step('final settings', () => _sessionWrite);
    debugPrint('Shutdown total: ${timer.elapsedMilliseconds} ms');
    timings.add('Total: ${timer.elapsedMilliseconds} ms');
    // Keep the last shutdown breakdown available in installed Release builds.
    // Diagnostic I/O must never prevent the window from closing.
    try {
      await (() async {
        final settings = widget.sessionFile ?? await _sessionFile();
        await File(
          p.join(settings.parent.path, 'shutdown-timing.log'),
        ).writeAsString('${timings.join('\n')}\n');
      })().timeout(const Duration(milliseconds: 500));
    } catch (_) {}
    await windowManager.destroy();
  }

  void _onLayoutWidth(double width) {
    if (width == _committedWidth) return;
    _pendingWidth = width;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _committedWidth = _pendingWidth);
    });
  }

  @override
  void dispose() {
    _rememberScrollPosition();
    _resizeTimer?.cancel();
    _sessionTimer?.cancel();
    if (!_closingWindow) _writeSession();
    windowManager.removeListener(this);
    unawaited(_standbyEmbedder?.dispose() ?? Future<void>.value());
    unawaited(_receiver?.close() ?? Future<void>.value());
    unawaited(_tagSuggester?.dispose() ?? Future<void>.value());
    unawaited(_classifier?.dispose() ?? Future<void>.value());
    final library = _library;
    unawaited(_stopSimilarity().then((_) => library?.close()));
    _scrollController.dispose();
    _galleryFocus.dispose();
    super.dispose();
  }

  int _columnCount(double availableWidth) =>
      (availableWidth / _tileSize).floor().clamp(1, 999);

  Rect? get _selectionRect {
    if (_dragStart == null || _dragCurrent == null) return null;
    return Rect.fromPoints(_dragStart!, _dragCurrent!);
  }

  String? _tileAt(Offset position) {
    final gridBox = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (gridBox == null) return null;
    for (final path in _imagePaths) {
      final tileBox =
          _tileKeys[path]?.currentContext?.findRenderObject() as RenderBox?;
      if (tileBox == null) continue;
      final offset = tileBox.localToGlobal(Offset.zero, ancestor: gridBox);
      if ((offset & tileBox.size).contains(position)) return path;
    }
    return null;
  }

  // Drags the selection, or just the pressed tile when it is not selected.
  // The native drag loop runs until the drop; drops back onto this window are
  // ignored rather than re-imported.
  Future<void> _startFileDrag(String path) async {
    if (!_selectedPaths.contains(path)) {
      setState(
        () => _selectedPaths
          ..clear()
          ..add(path),
      );
    }
    final paths = [
      for (final candidate in _imagePaths)
        if (_selectedPaths.contains(candidate) &&
            _assetsByPath[candidate]?.missing == false)
          candidate,
    ];
    if (paths.isEmpty) return;
    _draggingOut = true;
    try {
      await _dragChannel.invokeMethod<bool>('startFileDrag', paths);
    } on MissingPluginException {
      // Only the Windows runner can start an outgoing file drag.
    } on PlatformException {
      // Nothing was dragged; the selection is unchanged.
    } finally {
      _draggingOut = false;
    }
  }

  void _updateMarqueeSelection() {
    final rect = _selectionRect;
    if (rect == null) return;
    final gridBox = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (gridBox == null) return;

    final selected = <String>{};
    for (final path in _imagePaths) {
      final tileBox =
          _tileKeys[path]?.currentContext?.findRenderObject() as RenderBox?;
      if (tileBox == null) continue;
      // Convert tile position to grid-local coordinates
      final tileOffset = tileBox.localToGlobal(Offset.zero, ancestor: gridBox);
      final tileRect = tileOffset & tileBox.size;
      if (rect.overlaps(tileRect)) selected.add(path);
    }
    setState(
      () => _selectedPaths
        ..clear()
        ..addAll(selected),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: MenuBar(
          style: const MenuStyle(
            backgroundColor: WidgetStatePropertyAll(Colors.transparent),
            elevation: WidgetStatePropertyAll(0),
            padding: WidgetStatePropertyAll(EdgeInsets.zero),
          ),
          children: [
            SubmenuButton(
              menuChildren: [
                MenuItemButton(
                  onPressed: _busy ? null : _createLibrary,
                  child: const Text('New library…'),
                ),
                MenuItemButton(
                  onPressed: _busy ? null : _openLibrary,
                  child: const Text('Open library…'),
                ),
                MenuItemButton(
                  onPressed: _busy || _library == null ? null : _importImages,
                  child: const Text('Import images…'),
                ),
                MenuItemButton(
                  onPressed: _busy || _library == null
                      ? null
                      : _importFromDownloads,
                  child: const Text('Import from Downloads…'),
                ),
                MenuItemButton(
                  onPressed: _busy || _library == null ? null : _backupLibrary,
                  child: const Text('Back up metadata'),
                ),
                MenuItemButton(
                  onPressed: _busy || _library == null ? null : _closeLibrary,
                  child: const Text('Close library'),
                ),
                const Divider(),
                MenuItemButton(
                  onPressed: _busy ? null : () => windowManager.close(),
                  child: const Text('Quit'),
                ),
              ],
              child: const Text('File'),
            ),
            SubmenuButton(
              menuChildren: [
                MenuItemButton(
                  onPressed: _imagePaths.isEmpty
                      ? null
                      : () {
                          _galleryFocus.requestFocus();
                          setState(() => _selectedPaths.addAll(_imagePaths));
                        },
                  child: const Text('Select all'),
                ),
                MenuItemButton(
                  onPressed: _busy || _selectedPaths.isEmpty
                      ? null
                      : _editSelectionTags,
                  child: const Text('Edit tags…'),
                ),
                MenuItemButton(
                  onPressed: _busy || _selectedPaths.isEmpty
                      ? null
                      : _classifySelection,
                  child: const Text('ML classify'),
                ),
                MenuItemButton(
                  onPressed: _busy || _warmingModels || !_sessionRestored
                      ? null
                      : _configureOptions,
                  child: const Text('Options…'),
                ),
                MenuItemButton(
                  onPressed: _busy || _selectedPaths.isEmpty
                      ? null
                      : _archiveSelection,
                  child: Text(
                    _showArchived ? 'Restore selected' : 'Archive selected',
                  ),
                ),
              ],
              child: const Text('Edit'),
            ),
            SubmenuButton(
              menuChildren: [
                MenuItemButton(
                  onPressed: () {
                    setState(() => _tileSize = (_tileSize + 25).clamp(50, 400));
                    _persistSession();
                  },
                  child: const Text('Zoom in'),
                ),
                MenuItemButton(
                  onPressed: _busy || _library == null
                      ? null
                      : () => _run(() async {
                          _showArchived = !_showArchived;
                          _untagged = false;
                          _tagFilter = null;
                          await _reload();
                        }),
                  child: Text(_showArchived ? 'Show library' : 'Show archive'),
                ),
                MenuItemButton(
                  onPressed: _busy || _library == null ? null : _refreshLibrary,
                  child: const Text('Refresh files'),
                ),
                MenuItemButton(
                  onPressed: () {
                    setState(() => _tileSize = (_tileSize - 25).clamp(50, 400));
                    _persistSession();
                  },
                  child: const Text('Zoom out'),
                ),
              ],
              child: const Text('View'),
            ),
            SubmenuButton(
              menuChildren: [
                MenuItemButton(
                  onPressed: () => showAboutDialog(
                    context: context,
                    applicationName: 'Umbra Tags',
                    applicationVersion: 'Library format 1',
                  ),
                  child: const Text('About'),
                ),
              ],
              child: const Text('Help'),
            ),
          ],
        ),
        titleSpacing: 0,
        actions: [
          SegmentedButton<LayoutMode>(
            segments: const [
              ButtonSegment(
                value: LayoutMode.crop,
                icon: Icon(Icons.grid_view_rounded, semanticLabel: 'Crop'),
                tooltip: 'Crop — fill uniform tiles',
              ),
              ButtonSegment(
                value: LayoutMode.letterbox,
                icon: Icon(Icons.fit_screen_rounded, semanticLabel: 'Fit'),
                tooltip: 'Fit — show the whole image',
              ),
              ButtonSegment(
                value: LayoutMode.masonry,
                icon: Icon(Icons.view_quilt_rounded, semanticLabel: 'Masonry'),
                tooltip: 'Masonry — arrange by image proportions',
              ),
            ],
            showSelectedIcon: false,
            selected: {_layout},
            onSelectionChanged: (s) {
              setState(() => _layout = s.first);
              _persistSession();
            },
          ),
          const SizedBox(width: 16),
          const Icon(Icons.photo_size_select_large),
          SizedBox(
            width: 180,
            child: Slider(
              value: _tileSize,
              min: 50,
              max: 400,
              label: '${_tileSize.round()}px',
              onChanged: (v) {
                setState(() => _tileSize = v);
                _persistSession();
              },
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              _previewVisible
                  ? Icons.view_sidebar
                  : Icons.view_sidebar_outlined,
            ),
            tooltip: _previewVisible ? 'Hide preview' : 'Show preview',
            onPressed: () {
              setState(() => _previewVisible = !_previewVisible);
              _persistSession();
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      bottomNavigationBar: Container(
        color: AppColors.darker,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            if (_busy) ...[
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _library?.name ?? 'Umbra Tags',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    _status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (_similarity != null) SimilarityStatus(controller: _similarity!),
            if (_selectedPaths.isNotEmpty)
              Text('${_selectedPaths.length} selected  '),
            if (_classifying)
              TextButton(
                onPressed: _cancelClassification
                    ? null
                    : () => setState(() => _cancelClassification = true),
                child: Text(
                  _cancelClassification ? 'Stopping…' : 'Cancel after image',
                ),
              ),
            if (widget.startReceiver)
              Tooltip(
                message: _receiverStatus,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(
                    Icons.browser_updated,
                    size: 20,
                    color: _receiver?.port != null
                        ? Colors.greenAccent
                        : Colors.orangeAccent,
                  ),
                ),
              ),
            if (_library != null)
              FilledButton.icon(
                onPressed: _busy ? null : _importImages,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Import images'),
              ),
          ],
        ),
      ),
      body: _library == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.photo_library_outlined,
                    size: 48,
                    color: Colors.white38,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Your images. Your library.',
                    style: TextStyle(fontSize: 24),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Keep each library in a folder you choose.',
                    style: TextStyle(color: Colors.white60),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 12,
                    children: [
                      FilledButton(
                        onPressed: _busy ? null : _createLibrary,
                        child: const Text('New library'),
                      ),
                      OutlinedButton(
                        onPressed: _busy ? null : _openLibrary,
                        child: const Text('Open library'),
                      ),
                    ],
                  ),
                ],
              ),
            )
          : Row(
              children: [
                TagSidebar(
                  tags: _tags,
                  view: _showArchived
                      ? LibraryView.archived
                      : _untagged
                      ? LibraryView.untagged
                      : LibraryView.all,
                  selectedTag: _tagFilter,
                  busy: _busy,
                  onView: (view) => _setFilter(view),
                  onSelect: (id) => _setFilter(LibraryView.all, id),
                  onCreate: (parent) => _editTag(parent: parent),
                  onEdit: (tag) => _editTag(tag: tag),
                  onDelete: _deleteTag,
                  onFindMatches: _findTagMatches,
                  onToggleExcluded: _toggleTagExcluded,
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Column(
                    children: [
                      ViewBreadcrumbs(
                        tags: _tags,
                        view: _showArchived
                            ? LibraryView.archived
                            : _untagged
                            ? LibraryView.untagged
                            : LibraryView.all,
                        tagId: _tagFilter,
                        onView: _busy ? null : (view) => _setFilter(view),
                        onTag: _busy
                            ? null
                            : (id) => _setFilter(LibraryView.all, id),
                      ),
                      Expanded(
                        child: GalleryDropTarget(
                          enabled: !_busy && !_closingWindow,
                          onFiles: (files) {
                            if (!_draggingOut) {
                              _run(() => _importImageFiles(files));
                            }
                          },
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              _onLayoutWidth(constraints.maxWidth);
                              final width = _committedWidth > 0
                                  ? _committedWidth
                                  : constraints.maxWidth;
                              final cols = _columnCount(width);

                              if (_assets.isEmpty) {
                                return Center(
                                  child: Text(
                                    _showArchived
                                        ? 'No archived images'
                                        : _tagFilter != null || _untagged
                                        ? 'No images match this filter'
                                        : 'Import images to fill this library',
                                    style: const TextStyle(
                                      color: Colors.white54,
                                    ),
                                  ),
                                );
                              }
                              Widget grid;
                              if (_pendingScrollOffset != null) {
                                WidgetsBinding.instance.addPostFrameCallback(
                                  (_) => _restoreScrollPosition(),
                                );
                              }
                              if (_layout == LayoutMode.masonry) {
                                grid = ExactMasonryView(
                                  key: _gridKey,
                                  controller: _scrollController,
                                  columns: cols,
                                  spacing: 8,
                                  aspectRatios: [
                                    for (final asset in _assets)
                                      asset.width / asset.height,
                                  ],
                                  itemBuilder: (context, index) => GalleryTile(
                                    key: _tileKeys[_imagePaths[index]],
                                    path: _imagePaths[index],
                                    thumbnail: _thumbnailFor(
                                      _imagePaths[index],
                                    ),
                                    aspectRatio:
                                        _assets[index].width /
                                        _assets[index].height,
                                    filename: _assets[index].originalFilename,
                                    tileSize: _tileSize,
                                    layout: _layout,
                                    selected: _selectedPaths.contains(
                                      _imagePaths[index],
                                    ),
                                    onTap: () =>
                                        _selectImage(_imagePaths[index]),
                                    onDoubleTap: _busy
                                        ? null
                                        : () => _openImageExternally(
                                            _imagePaths[index],
                                          ),
                                    onContextSelect: () =>
                                        _selectContextImage(_imagePaths[index]),
                                    onCopyImage: _busy
                                        ? null
                                        : () => _copyImageToClipboard(
                                            _imagePaths[index],
                                          ),
                                    onEditTags: _busy
                                        ? null
                                        : _editSelectionTags,
                                    onArchive: _busy ? null : _archiveSelection,
                                    archived: _showArchived,
                                    onDelete: _busy ? null : _deleteSelection,
                                    onRefine: _busy ? null : _refineSelection,
                                    canRefine: _canRefineSelection,
                                    onClassify: _busy
                                        ? null
                                        : _classifySelection,
                                    onSimilar: _busy
                                        ? null
                                        : () => _findSimilar(_assets[index]),
                                    onTagDropped: _busy
                                        ? null
                                        : (tag) => _applyDroppedTag(
                                            _imagePaths[index],
                                            tag,
                                          ),
                                    tagDropCount:
                                        _selectedPaths.contains(
                                          _imagePaths[index],
                                        )
                                        ? _selectedPaths.length
                                        : 1,
                                  ),
                                );
                              } else {
                                grid = GridView.builder(
                                  key: _gridKey,
                                  controller: _scrollController,
                                  itemCount: _imagePaths.length,
                                  gridDelegate:
                                      SliverGridDelegateWithMaxCrossAxisExtent(
                                        maxCrossAxisExtent: _tileSize,
                                        mainAxisSpacing: 8,
                                        crossAxisSpacing: 8,
                                      ),
                                  itemBuilder: (context, index) => GalleryTile(
                                    key: _tileKeys[_imagePaths[index]],
                                    path: _imagePaths[index],
                                    thumbnail: _thumbnailFor(
                                      _imagePaths[index],
                                    ),
                                    aspectRatio:
                                        _assets[index].width /
                                        _assets[index].height,
                                    filename: _assets[index].originalFilename,
                                    tileSize: _tileSize,
                                    layout: _layout,
                                    selected: _selectedPaths.contains(
                                      _imagePaths[index],
                                    ),
                                    onTap: () =>
                                        _selectImage(_imagePaths[index]),
                                    onDoubleTap: _busy
                                        ? null
                                        : () => _openImageExternally(
                                            _imagePaths[index],
                                          ),
                                    onContextSelect: () =>
                                        _selectContextImage(_imagePaths[index]),
                                    onCopyImage: _busy
                                        ? null
                                        : () => _copyImageToClipboard(
                                            _imagePaths[index],
                                          ),
                                    onEditTags: _busy
                                        ? null
                                        : _editSelectionTags,
                                    onArchive: _busy ? null : _archiveSelection,
                                    archived: _showArchived,
                                    onDelete: _busy ? null : _deleteSelection,
                                    onRefine: _busy ? null : _refineSelection,
                                    canRefine: _canRefineSelection,
                                    onClassify: _busy
                                        ? null
                                        : _classifySelection,
                                    onSimilar: _busy
                                        ? null
                                        : () => _findSimilar(_assets[index]),
                                    onTagDropped: _busy
                                        ? null
                                        : (tag) => _applyDroppedTag(
                                            _imagePaths[index],
                                            tag,
                                          ),
                                    tagDropCount:
                                        _selectedPaths.contains(
                                          _imagePaths[index],
                                        )
                                        ? _selectedPaths.length
                                        : 1,
                                  ),
                                );
                              }

                              return Focus(
                                focusNode: _galleryFocus,
                                onKeyEvent: (node, event) {
                                  if (event is KeyDownEvent &&
                                      event.logicalKey ==
                                          LogicalKeyboardKey.delete &&
                                      !_busy &&
                                      _selectedPaths.isNotEmpty) {
                                    _deleteSelection();
                                    return KeyEventResult.handled;
                                  }
                                  return KeyEventResult.ignored;
                                },
                                child: ScrollConfiguration(
                                  behavior: _GalleryScrollBehavior(),
                                  child: Scrollbar(
                                    controller: _scrollController,
                                    thumbVisibility: true,
                                    interactive: true,
                                    scrollbarOrientation:
                                        ScrollbarOrientation.right,
                                    thickness: 8,
                                    radius: const Radius.circular(4),
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 20),
                                      // Keep scrollbar drags outside selection hit testing.
                                      child: Listener(
                                        onPointerDown: (e) {
                                          final keys =
                                              HardwareKeyboard.instance;
                                          _toggleOnTap =
                                              keys.isControlPressed ||
                                              keys.isMetaPressed;
                                          _rangeOnTap = keys.isShiftPressed;
                                          // Left button only, not the scroll wheel.
                                          if (_busy ||
                                              e.kind !=
                                                  PointerDeviceKind.mouse ||
                                              e.buttons !=
                                                  kPrimaryMouseButton) {
                                            return;
                                          }
                                          _galleryFocus.requestFocus();
                                          if (keys.isAltPressed) {
                                            setState(() {
                                              _dragStart = e.localPosition;
                                              _dragCurrent = e.localPosition;
                                            });
                                          } else {
                                            _fileDragOrigin = e.localPosition;
                                            _fileDragPath = _tileAt(
                                              e.localPosition,
                                            );
                                          }
                                        },
                                        onPointerMove: (e) {
                                          if (_dragStart != null) {
                                            setState(
                                              () => _dragCurrent =
                                                  e.localPosition,
                                            );
                                            _updateMarqueeSelection();
                                          } else if (_fileDragPath != null &&
                                              (e.localPosition -
                                                          _fileDragOrigin!)
                                                      .distance >
                                                  kTouchSlop / 3) {
                                            final path = _fileDragPath!;
                                            _fileDragPath = _fileDragOrigin =
                                                null;
                                            _startFileDrag(path);
                                          }
                                        },
                                        onPointerUp: (_) => setState(() {
                                          _dragStart = null;
                                          _dragCurrent = null;
                                          _fileDragPath = _fileDragOrigin =
                                              null;
                                        }),
                                        onPointerCancel: (_) => setState(() {
                                          _dragStart = null;
                                          _dragCurrent = null;
                                          _fileDragPath = _fileDragOrigin =
                                              null;
                                        }),
                                        child: Stack(
                                          children: [
                                            grid,
                                            if (_selectionRect != null)
                                              Positioned.fill(
                                                child: IgnorePointer(
                                                  child: CustomPaint(
                                                    painter: _MarqueePainter(
                                                      _selectionRect!,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_previewVisible) ...[
                  // Drag handle
                  GestureDetector(
                    onHorizontalDragUpdate: (d) => setState(() {
                      _previewWidth = (_previewWidth - d.delta.dx).clamp(
                        150,
                        800,
                      );
                      _persistSession();
                    }),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeColumn,
                      child: Container(width: 6, color: Colors.white12),
                    ),
                  ),
                  // Preview pane
                  SizedBox(
                    width: _previewWidth.clamp(
                      150,
                      (MediaQuery.sizeOf(context).width - 500).clamp(150, 800),
                    ),
                    child: DecoratedBox(
                      decoration: const BoxDecoration(color: AppColors.darker),
                      child: Column(
                        children: [
                          Expanded(
                            child: SizedBox.expand(
                              child: _selectedPaths.isNotEmpty
                                  ? Image.file(
                                      File(_selectedPaths.first),
                                      fit: BoxFit.contain,
                                      cacheWidth:
                                          (_previewWidth *
                                                  MediaQuery.devicePixelRatioOf(
                                                    context,
                                                  ))
                                              .ceil(),
                                      errorBuilder: (_, _, _) => const Center(
                                        child: Text(
                                          'Original file is missing or unreadable',
                                        ),
                                      ),
                                    )
                                  : const Center(
                                      child: Text(
                                        'No image selected',
                                        style: TextStyle(color: Colors.white24),
                                      ),
                                    ),
                            ),
                          ),
                          if (_selectedPaths.isNotEmpty) ...[
                            PreviewDetails(
                              asset: _assetsByPath[_selectedPaths.first]!,
                              selectionCount: _selectedPaths.length,
                              onOpen:
                                  _busy ||
                                      _assetsByPath[_selectedPaths.first]!
                                          .missing
                                  ? null
                                  : _openPreviewExternally,
                            ),
                            SelectionTags(tags: _tags, assets: _selection),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class GalleryTile extends StatelessWidget {
  const GalleryTile({
    super.key,
    required this.path,
    required this.thumbnail,
    required this.aspectRatio,
    required this.filename,
    required this.tileSize,
    required this.layout,
    required this.selected,
    required this.onTap,
    this.onDoubleTap,
    this.onContextSelect,
    this.onCopyImage,
    this.onEditTags,
    this.onArchive,
    this.archived = false,
    this.onDelete,
    this.onClassify,
    this.onRefine,
    this.canRefine,
    this.onSimilar,
    this.onTagDropped,
    this.tagDropCount = 1,
  });

  final String path;
  final Future<String?> thumbnail;
  final double aspectRatio;
  final String filename;
  final double tileSize;
  final LayoutMode layout;
  final bool selected, archived;
  final bool Function()? canRefine;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap,
      onContextSelect,
      onCopyImage,
      onEditTags,
      onArchive,
      onDelete,
      onRefine,
      onClassify,
      onSimilar;

  /// Assigns a tag dragged from the sidebar; [tagDropCount] images receive it.
  final ValueChanged<LibraryTag>? onTagDropped;
  final int tagDropCount;

  @override
  Widget build(BuildContext context) {
    final image = FutureBuilder<String?>(
      future: thumbnail,
      builder: (context, snapshot) {
        final placeholder = ColoredBox(
          color: Colors.white10,
          child: Center(
            child: Icon(
              snapshot.connectionState == ConnectionState.waiting
                  ? Icons.image_outlined
                  : Icons.broken_image_outlined,
              color: Colors.white24,
            ),
          ),
        );
        if (snapshot.data == null) return placeholder;
        return LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.devicePixelRatioOf(context);
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            final decodeByHeight =
                layout == LayoutMode.crop &&
                height.isFinite &&
                aspectRatio > width / height;
            return Image.file(
              File(snapshot.data!),
              fit: layout == LayoutMode.crop ? BoxFit.cover : BoxFit.contain,
              cacheWidth: decodeByHeight
                  ? null
                  : (width * scale).ceil().clamp(1, 1280),
              cacheHeight: decodeByHeight
                  ? (height * scale).ceil().clamp(1, 1280)
                  : null,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => placeholder,
            );
          },
        );
      },
    );
    return DragTarget<LibraryTag>(
      onWillAcceptWithDetails: (_) => onTagDropped != null,
      onAcceptWithDetails: (details) => onTagDropped?.call(details.data),
      builder: (context, candidates, _) => GestureDetector(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        onSecondaryTapUp: (d) => _showContextMenu(context, d.globalPosition),
        child: Stack(
          fit: layout == LayoutMode.masonry ? StackFit.loose : StackFit.expand,
          children: [
            layout == LayoutMode.masonry
                ? AspectRatio(aspectRatio: aspectRatio, child: image)
                : ColoredBox(color: AppColors.lighter, child: image),
            if (selected || candidates.isNotEmpty)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: candidates.isNotEmpty ? Colors.black45 : null,
                    border: Border.all(
                      color: AppColors.accent,
                      width: candidates.isNotEmpty ? 3 : 2,
                    ),
                  ),
                ),
              ),
            if (candidates.isNotEmpty)
              Positioned.fill(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      tagDropCount > 1
                          ? 'Add to $tagDropCount images'
                          : 'Add tag',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    onContextSelect?.call();
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: [
        PopupMenuItem(
          value: 'copyImage',
          enabled: onCopyImage != null,
          child: const Text('Copy image to clipboard'),
        ),
        PopupMenuItem(
          value: 'tags',
          enabled: onEditTags != null,
          child: const Row(
            children: [
              Icon(Icons.label_outline, size: 18),
              SizedBox(width: 10),
              Text('Edit tags…'),
            ],
          ),
        ),
        const PopupMenuItem(value: 'copy', child: Text('Copy file path')),
        const PopupMenuItem(value: 'info', child: Text('Image info')),
        PopupMenuItem(
          value: 'similar',
          enabled: onSimilar != null,
          child: const Text('Find similar'),
        ),
        if (onRefine != null && (canRefine?.call() ?? false))
          const PopupMenuItem(value: 'refine', child: Text('AI refine tags…')),
        PopupMenuItem(
          value: 'classify',
          enabled: onClassify != null,
          child: const Text('ML classify'),
        ),
        PopupMenuItem(
          value: 'archive',
          enabled: onArchive != null,
          child: Text(archived ? 'Restore from archive' : 'Archive'),
        ),
        PopupMenuItem(
          value: 'delete',
          enabled: onDelete != null,
          child: const Text('Delete'),
        ),
      ],
    );
    if (choice == 'copy') await Clipboard.setData(ClipboardData(text: path));
    if (choice == 'copyImage' && context.mounted) onCopyImage?.call();
    if (choice == 'tags' && context.mounted) onEditTags?.call();
    if (choice == 'archive' && context.mounted) onArchive?.call();
    if (choice == 'delete' && context.mounted) onDelete?.call();
    if (choice == 'refine' && context.mounted) onRefine?.call();
    if (choice == 'classify' && context.mounted) onClassify?.call();
    if (choice == 'similar' && context.mounted) onSimilar?.call();
    if (choice == 'info' && context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(filename),
          content: SelectableText(path),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    }
  }
}

class _MarqueePainter extends CustomPainter {
  _MarqueePainter(this.rect);
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      rect,
      Paint()
        ..color = AppColors.accent.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = AppColors.accent.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_MarqueePainter old) => old.rect != rect;
}

class _GalleryScrollBehavior extends ScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.trackpad,
  };

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child; // suppress built-in scrollbar — we render our own
}
