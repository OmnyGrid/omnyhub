/// The canonical OmnyHub package version (kept in sync with `pubspec.yaml`).
///
/// This is the single source of truth for "what build is this": it is rendered
/// in the CLI banner and advertised by a hub/node in its handshake. A test
/// (`test/unit/shared/version_test.dart`, tagged `version`) asserts it matches
/// `pubspec.yaml` so the two never drift.
const String omnyHubVersion = '1.6.0';
