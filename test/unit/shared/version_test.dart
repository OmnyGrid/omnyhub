@Tags(['version'])
library;

import 'dart:io';

import 'package:omnyhub/omnyhub.dart';
import 'package:test/test.dart';

void main() {
  test('omnyHubVersion matches pubspec.yaml version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'''^version:\s*['"]?([^\s'"]+)['"]?''',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'no version: line in pubspec.yaml');
    expect(omnyHubVersion, match!.group(1));
  });
}
