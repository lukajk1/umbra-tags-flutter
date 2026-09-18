import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gallery_test/receiver_server.dart';
import 'package:flutter_gallery_test/storage/library_store.dart';
import 'package:image/image.dart' as img;

void main() {
  late Directory temp;
  late LibraryStore library;
  late ReceiverServer receiver;
  late HttpClient client;
  late Uint8List picture;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('umbra-receiver-');
    library = await LibraryStore.create(temp.path, 'Web collection');
    picture = img.encodePng(img.Image(width: 120, height: 60));
    receiver = ReceiverServer(
      libraries: () async => [
        {'id': library.id, 'name': library.name},
      ],
      tags: (id) async {
        if (id != library.id) throw ReceiverException(404, 'Unknown library');
        return (await library.tags())
            .map((tag) => <String, Object?>{'id': tag.id, 'name': tag.name})
            .toList();
      },
      capture: (capture) async {
        if (capture.libraryId != library.id) {
          throw ReceiverException(404, 'Unknown library');
        }
        final imported = await library.importCapture(
          capture.bytes,
          filename: capture.filename,
          tagIds: capture.tagIds,
          maxDimension: capture.maxDimension,
        );
        return {'assetId': imported.asset.id, 'duplicate': imported.duplicate};
      },
    );
    await receiver.start(port: 0);
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await receiver.close();
    await library.close();
    await temp.delete(recursive: true);
  });
  Future<(int, Map)> request(
    String method,
    String path, {
    List<int>? body,
    String? origin = 'chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    bool header = true,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${receiver.port}$path'),
    );
    if (origin != null) request.headers.set('Origin', origin);
    if (header) request.headers.set('X-Umbra-Client', 'web-beam');
    if (body != null) request.add(body);
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return (response.statusCode, text.isEmpty ? {} : jsonDecode(text) as Map);
  }

  String upload({int size = 0, List<String> tags = const []}) =>
      '/upload?${Uri(queryParameters: {'libraryId': library.id, 'filename': '../example.webp', 'maxDimension': '$size', 'tagId': tags}).query}';

  test(
    'discovery and tagged resize persist through reopen; duplicates add tags',
    () async {
      final tag = await library.saveTag(name: 'Reference');
      final other = await library.saveTag(name: 'Lighting');
      expect(
        (await request('GET', '/libraries')).$2['libraries'],
        hasLength(1),
      );
      expect(
        (await request('GET', '/tags?libraryId=${library.id}')).$2['tags'],
        hasLength(2),
      );
      final imported = await request(
        'POST',
        upload(size: 60, tags: [tag]),
        body: picture,
      );
      expect(imported.$1, 200);
      var assets = await library.assets();
      expect(assets, hasLength(1));
      expect(assets.single.width, 60);
      expect(assets.single.height, 30);
      expect(assets.single.originalFilename, 'example.png');
      expect(assets.single.tagIds, [tag]);
      final duplicate = await request(
        'POST',
        upload(size: 60, tags: [other]),
        body: picture,
      );
      expect(duplicate.$2['duplicate'], true);
      expect(
        (await library.assets()).single.tagIds,
        unorderedEquals([tag, other]),
      );
      await library.close();
      library = await LibraryStore.open(temp.path);
      assets = await library.assets();
      expect(assets.single.tagIds, unorderedEquals([tag, other]));
      expect(
        img
            .decodeImage(
              await File(
                library.absolutePath(assets.single.relativePath),
              ).readAsBytes(),
            )!
            .width,
        60,
      );
    },
  );
  test(
    'zero and larger limits preserve original bytes without upscaling',
    () async {
      await request('POST', upload(size: 200), body: picture);
      expect(
        (await request('POST', upload(), body: picture)).$2['duplicate'],
        true,
      );
      final asset = (await library.assets()).single;
      expect(asset.width, 120);
      expect(
        await File(library.absolutePath(asset.relativePath)).readAsBytes(),
        picture,
      );
    },
  );
  test('rejects ordinary web origins and missing protocol header', () async {
    expect(
      (await request('GET', '/libraries', origin: 'https://example.com')).$1,
      403,
    );
    expect(
      (await request(
        'POST',
        upload(),
        body: picture,
        header: false,
        origin: null,
      )).$1,
      403,
    );
    expect((await request('OPTIONS', '/upload')).$1, 204);
    expect(await library.assets(), isEmpty);
  });
  test(
    'invalid bytes, deleted tags, dimensions and unknown libraries fail without an import',
    () async {
      expect((await request('POST', upload(), body: [1, 2, 3])).$1, 400);
      expect(
        (await request('POST', upload(tags: ['deleted']), body: picture)).$1,
        400,
      );
      expect((await request('POST', upload(size: -1), body: picture)).$1, 400);
      expect(
        (await request('POST', '/upload?libraryId=missing', body: picture)).$1,
        404,
      );
      expect(await library.assets(), isEmpty);
      expect(Directory('${temp.path}/staging').listSync(), isEmpty);
    },
  );
  test(
    'portrait resize and animated GIF retain dimensions and frames',
    () async {
      final first = img.Image(width: 30, height: 120)..frameDuration = 100;
      first.addFrame(img.Image(width: 30, height: 120)..frameDuration = 200);
      final result = await library.importCapture(
        img.encodeGif(first),
        filename: 'animation.gif',
        maxDimension: 60,
      );
      final decoded = img.decodeGif(
        await File(
          library.absolutePath(result.asset.relativePath),
        ).readAsBytes(),
      )!;
      expect(decoded.width, 15);
      expect(decoded.height, 60);
      expect(decoded.numFrames, 2);
    },
  );
  test('receiver releases its port on close', () async {
    final port = receiver.port!;
    await receiver.close();
    final replacement = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    await replacement.close(force: true);
  });
}
