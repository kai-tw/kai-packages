import 'dart:convert';
import 'dart:io';

/// Replaces a file's content with JSON so that a reader sees either the old
/// content or the new, never a truncated mix.
///
/// Writes a sibling file in the same directory — a rename is only atomic
/// within one file system — then renames it over the target. The sibling's
/// name does not end in `.json`, so a directory sweep never picks it up.
class JsonFileAtomicWriter {
  const JsonFileAtomicWriter();

  Future<void> write(File file, Map<String, dynamic> json) async {
    final String encoded = jsonEncode(json);
    final File staging = File('${file.path}.tmp');
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
}
