import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

String? value(List<HeaderField> headers, String name) {
  final all = headers.where((h) => h.name.toLowerCase() == name.toLowerCase());
  expect(all.length, lessThanOrEqualTo(1), reason: '$name must be collapsed');
  return all.isEmpty ? null : all.single.value;
}

void main() {
  const plain = [(name: 'Host', value: 'example.com:20001')];

  test('adds every forwarding header for a plain HTTP hop', () {
    final out = const ForwardedHeaders(
      clientAddress: '203.0.113.7',
      port: 20001,
      via: 'omnyshell-hub',
    ).apply(plain);
    expect(value(out, 'Host'), 'example.com:20001');
    expect(value(out, 'X-Forwarded-For'), '203.0.113.7');
    expect(value(out, 'X-Forwarded-Proto'), 'http');
    expect(value(out, 'X-Forwarded-Host'), 'example.com:20001');
    expect(value(out, 'X-Forwarded-Port'), '20001');
    expect(value(out, 'X-Forwarded-Ssl'), 'off');
    expect(value(out, 'X-Real-IP'), '203.0.113.7');
    expect(
      value(out, 'Forwarded'),
      'for=203.0.113.7;proto=http;host="example.com:20001"',
    );
    expect(value(out, 'Via'), '1.1 omnyshell-hub');
    expect(value(out, 'X-Request-Id'), isNull);
  });

  test('a secure hop reports https in every scheme header', () {
    final out = const ForwardedHeaders(
      clientAddress: '203.0.113.7',
      secure: true,
    ).apply(plain);
    expect(value(out, 'X-Forwarded-Proto'), 'https');
    expect(value(out, 'X-Forwarded-Ssl'), 'on');
    expect(value(out, 'Forwarded'), contains('proto=https'));
  });

  test('appends to list-valued headers the client already sent', () {
    final out = const ForwardedHeaders(clientAddress: '10.0.0.2').apply([
      ...plain,
      (name: 'x-forwarded-for', value: '1.1.1.1'),
      (name: 'X-Forwarded-For', value: '2.2.2.2'),
      (name: 'Forwarded', value: 'for=1.1.1.1'),
      (name: 'via', value: '1.0 upstream'),
      (name: 'X-Forwarded-Proto', value: 'https'),
    ]);
    expect(value(out, 'X-Forwarded-For'), '1.1.1.1, 2.2.2.2, 10.0.0.2');
    expect(value(out, 'X-Forwarded-Proto'), 'https, http');
    expect(
      value(out, 'Forwarded'),
      'for=1.1.1.1, for=10.0.0.2;proto=http;host="example.com:20001"',
    );
    expect(value(out, 'Via'), '1.0 upstream, 1.1 omnyhub');
  });

  test('keeps single-valued headers the client already sent', () {
    var minted = 0;
    final hop = ForwardedHeaders(
      clientAddress: '10.0.0.2',
      secure: true,
      requestId: () => 'id-${++minted}',
    );
    final kept = hop.apply([
      ...plain,
      (name: 'X-Real-IP', value: '1.1.1.1'),
      (name: 'X-Forwarded-Ssl', value: 'off'),
      (name: 'X-Request-Id', value: 'abc'),
    ]);
    expect(value(kept, 'X-Real-IP'), '1.1.1.1');
    expect(value(kept, 'X-Forwarded-Ssl'), 'off');
    expect(value(kept, 'X-Request-Id'), 'abc');
    expect(minted, 0);

    final fresh = hop.apply(plain);
    expect(value(fresh, 'X-Request-Id'), 'id-1');
  });

  test('extra headers are appended like the list-valued ones', () {
    final out = const ForwardedHeaders(
      extra: {'X-OmnyShell-Node': 'web-01', 'X-OmnyShell-Tunnel-Id': 'ab12'},
    ).apply([...plain, (name: 'x-omnyshell-node', value: 'spoofed')]);
    expect(value(out, 'X-OmnyShell-Node'), 'spoofed, web-01');
    expect(value(out, 'X-OmnyShell-Tunnel-Id'), 'ab12');
  });

  test(
    'unrelated fields keep their order and case, managed ones move last',
    () {
      final out = const ForwardedHeaders().apply([
        (name: 'X-Forwarded-For', value: '1.1.1.1'),
        (name: 'Host', value: 'h'),
        (name: 'accept', value: '*/*'),
      ]);
      expect(out.take(2).toList(), [
        (name: 'Host', value: 'h'),
        (name: 'accept', value: '*/*'),
      ]);
      expect(value(out, 'X-Forwarded-For'), '1.1.1.1');
    },
  );

  test('IPv6 clients are bracketed and quoted in Forwarded', () {
    final out = const ForwardedHeaders(
      clientAddress: '2001:db8::1',
    ).apply(plain);
    expect(value(out, 'X-Forwarded-For'), '2001:db8::1');
    expect(value(out, 'Forwarded'), startsWith('for="[2001:db8::1]";'));
  });

  test('falls back to the configured host when the request has none', () {
    final out = const ForwardedHeaders(host: 'hub.example:443').apply([]);
    expect(value(out, 'X-Forwarded-Host'), 'hub.example:443');
    expect(value(out, 'Forwarded'), 'proto=http;host="hub.example:443"');
    expect(value(out, 'X-Forwarded-For'), isNull);
    expect(value(out, 'X-Real-IP'), isNull);
    expect(value(out, 'X-Forwarded-Port'), isNull);
  });

  test('quotes and escapes a host that needs it', () {
    final out = const ForwardedHeaders().apply([
      (name: 'Host', value: r'a"b\c'),
    ]);
    expect(value(out, 'Forwarded'), r'proto=http;host="a\"b\\c"');
  });

  test('strips control characters so a value cannot inject a header line', () {
    final out = const ForwardedHeaders(
      extra: {'X-Ctx': 'ok\r\nX-Evil: 1'},
    ).apply(plain);
    expect(value(out, 'X-Ctx'), 'okX-Evil: 1');
    expect(value(out, 'X-Evil'), isNull);
  });

  test('uses the request version in Via', () {
    final out = const ForwardedHeaders().apply(plain, httpVersion: '1.0');
    expect(value(out, 'Via'), '1.0 omnyhub');
  });

  test('proto reflects secure', () {
    expect(const ForwardedHeaders().proto, 'http');
    expect(const ForwardedHeaders(secure: true).proto, 'https');
  });
}
