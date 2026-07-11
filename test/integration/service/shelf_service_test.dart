@TestOn('vm')
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:omnyhub/omnyhub.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart' as shelf_router;
import 'package:test/test.dart';

void main() {
  late OmnyHub hub;
  late String base;

  setUp(() async {
    // An existing shelf_router.Router with path parameters, hosted verbatim.
    final router = shelf_router.Router()
      ..get('/drives/<endpoint>/<name>', (
        shelf.Request r,
        String endpoint,
        String name,
      ) {
        return shelf.Response.ok(
          jsonEncode({'endpoint': endpoint, 'name': name}),
          headers: {'content-type': 'application/json'},
        );
      })
      ..get('/drives/<endpoint>/<name>/files/<path|.*>', (
        shelf.Request r,
        String endpoint,
        String name,
        String path,
      ) {
        return shelf.Response.ok('file:$path');
      })
      ..put('/drives/<endpoint>/<name>/files/<path|.*>', (
        shelf.Request r,
        String endpoint,
        String name,
        String path,
      ) async {
        return shelf.Response.ok('put:$path:${await r.readAsString()}');
      });

    hub = OmnyHub(
      transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
    );
    await hub.registerService(
      ShelfService(router.call, name: 'drive', mount: '/drives'),
    );
    await hub.start();
    base = 'http://127.0.0.1:${hub.port}';
  });

  tearDown(() => hub.stop());

  test('wraps a shelf_router with path params verbatim', () async {
    final drive = await http.get(Uri.parse('$base/drives/laptop/docs'));
    expect(jsonDecode(drive.body), {'endpoint': 'laptop', 'name': 'docs'});

    final file = await http.get(
      Uri.parse('$base/drives/laptop/docs/files/a/b.txt'),
    );
    expect(file.body, 'file:a/b.txt');

    final put = await http.put(
      Uri.parse('$base/drives/laptop/docs/files/x.txt'),
      body: 'BYTES',
    );
    expect(put.body, 'put:x.txt:BYTES');
  });

  test('unmatched shelf route returns 404 through the adapter', () async {
    final res = await http.get(Uri.parse('$base/drives/only-one-segment'));
    expect(res.statusCode, 404);
  });
}
