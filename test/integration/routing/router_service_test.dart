@TestOn('vm')
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

void main() {
  late OmnyHub hub;
  late String base;

  setUp(() async {
    hub = OmnyHub(
      transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
    );
    final router = RouterService(name: 'drive', mount: '/drives')
      ..get(
        '/drives/<endpoint>/<name>',
        (req, p) async =>
            HubResponse.json({'endpoint': p['endpoint'], 'name': p['name']}),
      )
      ..get(
        '/drives/<endpoint>/<name>/files/<path|.*>',
        (req, p) async => HubResponse.text('file:${p['path']}'),
      )
      ..put(
        '/drives/<endpoint>/<name>/files/<path|.*>',
        (req, p) async =>
            HubResponse.text('put:${p['path']}:${await req.readAsString()}'),
      );
    await hub.registerService(router);
    await hub.start();
    base = 'http://127.0.0.1:${hub.port}';
  });

  tearDown(() => hub.stop());

  test('captures path params and dispatches by method', () async {
    final drive = await http.get(Uri.parse('$base/drives/laptop/docs'));
    expect(jsonDecode(drive.body), {'endpoint': 'laptop', 'name': 'docs'});

    final file = await http.get(
      Uri.parse('$base/drives/laptop/docs/files/a/b.txt'),
    );
    expect(file.body, 'file:a/b.txt');

    final put = await http.put(
      Uri.parse('$base/drives/laptop/docs/files/x.txt'),
      body: 'DATA',
    );
    expect(put.body, 'put:x.txt:DATA');
  });

  test('405 when the path matches but the method does not', () async {
    final res = await http.delete(Uri.parse('$base/drives/laptop/docs'));
    expect(res.statusCode, 405);
  });

  test('404 when no pattern matches', () async {
    final res = await http.get(Uri.parse('$base/drives/laptop/docs/nope'));
    expect(res.statusCode, 404);
  });
}
