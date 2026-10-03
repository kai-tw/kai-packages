import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Replaces a file's content with JSON so that a reader sees either the old
/// content or the new, never a truncated mix.
///
/// Each write goes to its own staging sibling in the same directory — a rename
/// is only atomic within one file system — and is then renamed over the
/// target. Concurrent writes to one file therefore never share a staging file;
/// the last rename wins, and each target state is one complete payload.
///
/// A crash between the two steps leaves a stray `*.tmp` sibling. Its name never
/// ends in `.json`, so no read and no directory sweep ever touches it.
class JsonFileAtomicWriter {
  const JsonFileAtomicWriter();

  Future<void> write(File file, Map<String, dynamic> json) async {
    final String encoded = jsonEncode(json);
    final File staging = File(_stagingPath(file));
    try {
      await staging.writeAsString(encoded, flush: true);
      await staging.rename(file.path);
    } on FileSystemException {
      // The target is untouched; remove the partial sibling before reporting.
      if (await staging.exists()) {
        await staging.delete();
      }
      rethrow;
    }
  }

  /// A sibling path unique to this write: the process id separates processes,
  /// the random part separates writes within one process.
  static String _stagingPath(File file) {
    final String nonce = Random.secure()
        .nextInt(1 << 32)
        .toRadixString(16)
        .padLeft(8, '0');
    return '${file.path}.$pid-$nonce.tmp';
  }
}
