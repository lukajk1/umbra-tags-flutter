import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int kPort = 8934;
const int kMaxUploadBytes = 25 * 1024 * 1024;

class ReceiverException implements Exception {
  ReceiverException(this.status, this.message);
  final int status;
  final String message;
}

class WebCapture {
  WebCapture(
    this.libraryId,
    this.filename,
    this.tagIds,
    this.maxDimension,
    this.bytes,
  );
  final String libraryId, filename;
  final List<String> tagIds;
  final int maxDimension;
  final Uint8List bytes;
}

/// Owned by the desktop app. All file access is delegated to its library stores.
class ReceiverServer {
  ReceiverServer({
    required this.libraries,
    required this.tags,
    required this.capture,
  });
  final Future<List<Map<String, Object?>>> Function() libraries;
  final Future<List<Map<String, Object?>>> Function(String libraryId) tags;
  final Future<Map<String, Object?>> Function(WebCapture capture) capture;
  HttpServer? _server;
  bool _uploading = false;
  int? get port => _server?.port;

  Future<void> start({int port = kPort}) async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle);
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    var ownsUpload = false;
    try {
      final origin = request.headers.value('origin');
      final host = request.headers.value('host')?.split(':').first;
      if ((host != '127.0.0.1' && host != 'localhost') ||
          (origin != null &&
              !RegExp(r'^chrome-extension://[a-p]{32}$').hasMatch(origin))) {
        throw ReceiverException(
          403,
          'Only local browser extensions may use this receiver.',
        );
      }
      if (origin != null) {
        response.headers.set('Access-Control-Allow-Origin', origin);
      }
      response.headers.set('Vary', 'Origin');
      response.headers.set('Cache-Control', 'no-store');
      if (request.method == 'OPTIONS') {
        response.headers.set(
          'Access-Control-Allow-Methods',
          'GET, POST, OPTIONS',
        );
        response.headers.set(
          'Access-Control-Allow-Headers',
          'Content-Type, X-Umbra-Client',
        );
        response.statusCode = 204;
        return;
      }
      // Requiring a non-simple header also blocks ordinary HTML form submissions.
      if (request.headers.value('x-umbra-client') != 'web-beam') {
        throw ReceiverException(
          403,
          'Missing Umbra extension protocol header.',
        );
      }
      final path = request.uri.path;
      Object result;
      if (request.method == 'GET' && path == '/libraries') {
        result = {'ok': true, 'libraries': await libraries()};
      } else if (request.method == 'GET' && path == '/tags') {
        result = {
          'ok': true,
          'tags': await tags(request.uri.queryParameters['libraryId'] ?? ''),
        };
      } else if (request.method == 'POST' && path == '/upload') {
        if (_uploading) {
          throw ReceiverException(
            409,
            'Another image is arriving. Try again shortly.',
          );
        }
        _uploading = ownsUpload = true;
        final query = request.uri.queryParameters;
        final libraryId = query['libraryId'] ?? '';
        if (libraryId.isEmpty) {
          throw ReceiverException(
            400,
            'Choose a destination library in the extension.',
          );
        }
        final limit = int.tryParse(query['maxDimension'] ?? '0');
        if (limit == null || limit < 0 || limit > 16384) {
          throw ReceiverException(400, 'Maximum edge must be 0–16384 pixels.');
        }
        final tagIds = request.uri.queryParametersAll['tagId'] ?? <String>[];
        if (tagIds.length > 200 || tagIds.any((id) => id.length > 64)) {
          throw ReceiverException(400, 'Too many or invalid tags.');
        }
        if (request.contentLength > kMaxUploadBytes) {
          throw ReceiverException(413, 'Image exceeds 25 MB.');
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in request.timeout(
          const Duration(seconds: 30),
        )) {
          if (builder.length + chunk.length > kMaxUploadBytes) {
            throw ReceiverException(413, 'Image exceeds 25 MB.');
          }
          builder.add(chunk);
        }
        if (builder.isEmpty) throw ReceiverException(400, 'Image is empty.');
        result = {
          'ok': true,
          ...await capture(
            WebCapture(
              libraryId,
              query['filename'] ?? 'web-image',
              tagIds.toSet().toList(),
              limit,
              builder.takeBytes(),
            ),
          ),
        };
      } else {
        throw ReceiverException(404, 'Unknown receiver endpoint.');
      }
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(result));
    } catch (error) {
      response.statusCode = error is ReceiverException
          ? error.status
          : error is TimeoutException
          ? 408
          : 400;
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({
          'ok': false,
          'error': error is ReceiverException
              ? error.message
              : error.toString(),
        }),
      );
    } finally {
      if (ownsUpload) _uploading = false;
      try {
        await response.close();
      } on HttpException {
        // A browser may close its popup or cancel an upload before the reply.
      } on SocketException {
        // A completed import remains saved even when the client disconnects.
      }
    }
  }
}
