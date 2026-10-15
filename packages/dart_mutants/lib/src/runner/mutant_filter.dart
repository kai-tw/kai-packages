import 'dart:convert';

import '../mutant.dart';

/// Narrows one file's [mutants] to the ones a review should look at: those on
/// [lines] when given (a diff's changed lines, say), and at most [perLine] on
/// any one line. The rest are not run, scored or reported.
///
/// Which mutants a line keeps is decided by a hash of each mutant, not by
/// order or chance, so the same code always keeps the same ones — a journal
/// from an earlier start still names them — and a line's pick does not
/// favour whichever operator happens to run first.
List<Mutant> narrowMutants(
  List<Mutant> mutants, {
  Set<int>? lines,
  int? perLine,
}) {
  final List<Mutant> onLines = lines == null
      ? mutants
      : mutants.where((Mutant m) => lines.contains(m.line)).toList();
  if (perLine == null) {
    return onLines;
  }
  final Map<int, List<Mutant>> byLine = <int, List<Mutant>>{};
  for (final Mutant m in onLines) {
    byLine.putIfAbsent(m.line, () => <Mutant>[]).add(m);
  }
  final Set<Mutant> kept = <Mutant>{
    for (final List<Mutant> line in byLine.values)
      ...(line.toList()
            ..sort((Mutant a, Mutant b) => _rank(a).compareTo(_rank(b))))
          .take(perLine),
  };
  return onLines.where(kept.contains).toList();
}

/// A stable 32-bit FNV-1a hash of what makes [m] the mutant it is.
int _rank(Mutant m) {
  int hash = 0x811c9dc5;
  for (final int byte in utf8.encode(
    '${m.offset}:${m.length}:${m.operatorName}:${m.replacement}',
  )) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash;
}
