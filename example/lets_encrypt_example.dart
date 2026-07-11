// Serves an HTTPS site whose certificate is provisioned and renewed
// automatically via Let's Encrypt (ACME HTTP-01).
//
// Unlike the other examples this one talks to a real certificate authority, so
// it needs:
//   * a public DNS name pointing at this machine, and
//   * reachable ports 80 (ACME HTTP-01 challenge) and 443 (HTTPS).
//
// It is therefore a DRY RUN by default — it builds and describes the hub but
// does not bind privileged ports or contact the CA. Pass `--run` on a properly
// configured host to actually start it.
//
// Usage:
//   dart run example/lets_encrypt_example.dart <domain> <email> [--run] \
//       [--production] [--cache <dir>]
//
// Example (staging, dry run):
//   dart run example/lets_encrypt_example.dart example.com ops@example.com
//
// Example (real issuance on a server):
//   sudo dart run example/lets_encrypt_example.dart example.com ops@example.com \
//       --run --production --cache /var/lib/omnyhub/certs
import 'dart:io';

import 'package:omnyhub/omnyhub.dart';

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length < 2) {
    stderr.writeln(
      'Usage: lets_encrypt_example <domain> <email> '
      '[--run] [--production] [--cache <dir>]',
    );
    exitCode = 64;
    return;
  }

  final domain = positional[0];
  final email = positional[1];
  final run = args.contains('--run');
  final production = args.contains('--production');
  final cacheDir = _optionValue(args, '--cache') ?? 'certs';

  // The auto-TLS provider. `production: false` (the default) uses Let's
  // Encrypt *staging*, whose certificates are browser-invalid but avoid the
  // strict production rate limits — switch to production only once issuance
  // works end-to-end.
  final tls = LetsEncryptTls(
    domains: [Domain(name: domain, email: email)],
    cacheDir: cacheDir,
    production: production,
  );

  final hub = OmnyHub(
    transports: [
      // Port 80 answers the ACME HTTP-01 challenge (mounted automatically) and
      // can redirect/serve plain HTTP.
      HttpTransport.http(port: 80),
      // Port 443 serves HTTPS with the auto-provisioned certificate. On start()
      // the hub provisions certificates (validated via the challenge on :80),
      // then binds this listener; it hot-reloads the listener on renewal.
      HttpTransport.https(port: 443, tls: tls),
    ],
    // Check for renewal twice a day (the default); certificates renew when they
    // are close to expiry, and the HTTPS listener rebinds automatically.
    tlsRenewalInterval: const Duration(hours: 12),
  );

  await hub.registerService(
    HandlerService(
      name: 'site',
      handler: (req) async =>
          HubResponse.text('Hello from $domain over ${req.protocol.name}!'),
    ),
  );

  if (!run) {
    stdout.writeln('Dry run — configuration is valid but nothing was started.');
    stdout.writeln('  domain     : $domain');
    stdout.writeln('  email      : $email');
    stdout.writeln('  environment: ${production ? 'production' : 'staging'}');
    stdout.writeln('  cacheDir   : $cacheDir');
    stdout.writeln(
      'Re-run with --run on a host that owns $domain and can '
      'accept traffic on ports 80 and 443.',
    );
    return;
  }

  stdout.writeln('Provisioning certificate for $domain and starting...');
  await hub.start();
  stdout.writeln('Serving https://$domain/  (Ctrl-C to stop)');

  await ProcessSignal.sigint.watch().first;
  stdout.writeln('\nShutting down...');
  await hub.stop();
}

String? _optionValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index >= 0 && index + 1 < args.length) return args[index + 1];
  return null;
}
