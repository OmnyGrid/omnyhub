// Demonstrates path-parameter routing with the native RouterService — capturing
// segments and a wildcard tail, dispatching by method. (A ShelfService can wrap
// an existing shelf_router.Router the same way.)
//
// Run with: dart run example/path_params_example.dart
import 'package:http/http.dart' as http;
import 'package:omnyhub/omnyhub.dart';

Future<void> main() async {
  final drives = RouterService(name: 'drives', mount: '/drives')
    ..get(
      '/drives/<endpoint>/<name>',
      (req, p) async =>
          HubResponse.json({'endpoint': p['endpoint'], 'name': p['name']}),
    )
    ..get(
      '/drives/<endpoint>/<name>/files/<path|.*>',
      (req, p) async => HubResponse.text('read ${p['path']}'),
    )
    ..put(
      '/drives/<endpoint>/<name>/files/<path|.*>',
      (req, p) async =>
          HubResponse.text('wrote ${p['path']} (${await req.readAsString()})'),
    );

  final hub = OmnyHub(
    transports: [HttpTransport.http(address: '127.0.0.1', port: 0)],
  );
  await hub.registerService(drives);
  await hub.start();
  final base = 'http://127.0.0.1:${hub.port}';

  print(
    'GET  /drives/laptop/docs            -> '
    '${(await http.get(Uri.parse('$base/drives/laptop/docs'))).body}',
  );
  print(
    'GET  /drives/laptop/docs/files/a/b  -> '
    '${(await http.get(Uri.parse('$base/drives/laptop/docs/files/a/b.txt'))).body}',
  );
  final put = await http.put(
    Uri.parse('$base/drives/laptop/docs/files/note.txt'),
    body: 'hello',
  );
  print('PUT  .../files/note.txt             -> ${put.body}');
  final wrongMethod = await http.delete(Uri.parse('$base/drives/laptop/docs'));
  print(
    'DELETE .../docs (no handler)        -> ${wrongMethod.statusCode} (405)',
  );

  await hub.stop();
}
