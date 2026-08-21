// Standalone MVP receiver: run with `dart run lib/receiver_server.dart`.
// Listens for POST /upload requests with raw image bytes and saves them
// to disk. Not wired into the Flutter app yet — this just proves the
// extension -> local server round trip works.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int kPort = 8934;
const int kMaxUploadBytes = 25 * 1024 * 1024; // 25 MB

Future<Directory> _incomingDir() async {
  final appData = Platform.environment['APPDATA'] ?? '.';
  final dir = Directory('$appData/Umbra Tags/incoming');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

void _addCorsHeaders(HttpResponse response) {
  response.headers.set('Access-Control-Allow-Origin', '*');
  response.headers.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
  response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
}

bool _startsWith(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

/// Determines the real image type from magic bytes, ignoring whatever the
/// client claimed via Content-Type. Returns null if the bytes don't match
/// a known image signature.
String? _extensionFromMagicBytes(Uint8List bytes) {
  if (_startsWith(bytes, [0xFF, 0xD8, 0xFF])) return 'jpg';
  if (_startsWith(bytes, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'png';
  }
  if (_startsWith(bytes, [0x47, 0x49, 0x46, 0x38])) return 'gif'; // GIF8
  if (bytes.length >= 12 &&
      _startsWith(bytes, [0x52, 0x49, 0x46, 0x46]) && // 'RIFF'
      bytes[8] == 0x57 && // 'W'
      bytes[9] == 0x45 && // 'E'
      bytes[10] == 0x42 && // 'B'
      bytes[11] == 0x50) {
    // 'P'
    return 'webp';
  }
  return null;
}

/// Reads the request body up to [kMaxUploadBytes], throwing if exceeded so
/// we never buffer an unbounded amount of attacker-controlled data.
Future<Uint8List> _readBodyLimited(HttpRequest request) async {
  final builder = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in request) {
    total += chunk.length;
    if (total > kMaxUploadBytes) {
      throw StateError('Upload exceeds max size of $kMaxUploadBytes bytes');
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<void> main() async {
  // Loopback-only: do not change to anyIPv4 without re-adding auth, since
  // that would expose the upload endpoint to the whole LAN.
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, kPort);
  print('Receiver listening on http://localhost:$kPort');

  await for (final request in server) {
    _addCorsHeaders(request.response);

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      continue;
    }

    if (request.method == 'POST' && request.uri.path == '/upload') {
      try {
        final bytes = await _readBodyLimited(request);
        final ext = _extensionFromMagicBytes(bytes);
        if (ext == null) {
          print('Rejected upload: not a recognized image format');
          request.response.statusCode = HttpStatus.badRequest;
          request.response.headers.contentType = ContentType.json;
          request.response
              .write(jsonEncode({'ok': false, 'error': 'unrecognized image format'}));
          await request.response.close();
          continue;
        }

        final dir = await _incomingDir();
        final filename = '${DateTime.now().millisecondsSinceEpoch}.$ext';
        final file = File('${dir.path}/$filename');
        await file.writeAsBytes(bytes);

        print('Saved ${bytes.length} bytes -> ${file.path}');

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ok': true, 'file': filename}));
      } on StateError catch (e) {
        print('Rejected upload: $e');
        request.response.statusCode = HttpStatus.requestEntityTooLarge;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ok': false, 'error': '$e'}));
      } catch (e) {
        print('Error saving upload: $e');
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ok': false, 'error': '$e'}));
      }
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }

    await request.response.close();
  }
}
