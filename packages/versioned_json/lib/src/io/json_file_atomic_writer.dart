import 'dart:io';

/// Replaces a file's content so that a reader sees either the old content or
/// the new, never a truncated mix.
///
/// Each write goes to the staging file `<target>.tmp` in the same directory —
/// a rename is only atomic within one file system — is flushed, and is then
/// renamed over the target. The staging name is fixed, so a stray staging
/// file a crash left behind is reused by the next write rather than piling
/// up. It also means two writes to one target at the same time share that
/// file: the caller must not start a write to a target before the previous
/// one has finished.
///
/// A crash between the two steps leaves the stray `<target>.tmp`. Its name
/// never ends in `.json`, so no read and no directory sweep ever touches it.
class JsonFileAtomicWriter {
  const JsonFileAtomicWriter();

  Future<void> write(File file, List<int> bytes) async {
    final File staging = File('${file.path}.tmp');
    try {
      await staging.writeAsBytes(bytes, flush: true);
      await staging.rename(file.path);
    } on FileSystemException {
      // The target is untouched; remove the partial staging file before
      // reporting.
      if (await staging.exists()) {
        await staging.delete();
      }
      rethrow;
    }
  }
}
