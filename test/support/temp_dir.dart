import 'dart:io';

import 'package:path/path.dart' as p;

/// A throwaway temporary directory for tests. No automatic cleanup — register
/// [cleanup] with `addTearDown`.
class TempDir {
  /// The absolute path of the directory.
  final String path;

  TempDir._(this.path);

  /// Creates a fresh temporary directory under the system temp root.
  static Future<TempDir> create() async {
    final dir = await Directory.systemTemp.createTemp('omnyhub_test_');
    return TempDir._(dir.path);
  }

  /// Resolves [relative] against this directory.
  String resolve(String relative) => p.join(path, relative);

  /// Writes [contents] to [relative], creating parent directories.
  Future<File> writeFile(String relative, String contents) async {
    final file = File(resolve(relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
    return file;
  }

  /// Recursively deletes the directory, ignoring errors.
  Future<void> cleanup() async {
    try {
      await Directory(path).delete(recursive: true);
    } on Object {
      // Best-effort cleanup.
    }
  }
}
