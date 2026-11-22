import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

import '../../lint_rule_base.dart';
import 'feature_layout.dart';

/// Warns when a file in `lib/features/**/domain/` imports a package
/// forbidden by the "pure Dart only" constraint on the domain layer.
///
/// Domain code must not depend on Flutter, Firebase, platform plugins,
/// network/I/O packages, or state-management libraries — those imports
/// pull infrastructure into a layer that exists to be testable in pure
/// Dart and to be shared across UI/data implementations.
class DomainPureDartImports extends LintRule {
  DomainPureDartImports({List<String>? featureRoots, List<String>? layers})
    : layout = FeatureLayout(roots: featureRoots, layers: layers);

  final FeatureLayout layout;

  @override
  String get name => 'domain_pure_dart_imports';

  @override
  String get description =>
      'Avoid Flutter / plugin / network / state imports inside domain/. '
      'Keep domain pure Dart.';

  @override
  LintVisitor createVisitor(
    String filePath,
    LineInfo lineInfo,
    String source,
  ) => _Visitor(filePath, lineInfo, source, layout);
}

class _Visitor extends LintVisitor {
  _Visitor(super.filePath, super.lineInfo, super.source, this.layout);

  final FeatureLayout layout;

  /// Exact package URIs banned in domain/. Allowed: dart:*, equatable,
  /// collection, meta, rxdart (scoped — see note below), and other
  /// in-project domain files.
  ///
  /// Note on `package:rxdart`: intentionally absent from the ban list, because
  /// its `BehaviorSubject<T>` / `ValueStream<T>` / `Subject<T>` primitives are
  /// what close the broadcast-late-subscriber gap — a subscriber that arrives
  /// after the last emission otherwise sees nothing until the next one. That
  /// carve-out covers the primitives only; the operator surface
  /// (`combineLatest`, `switchMap`, `flatMap`, `merge`, `zip`, `debounceTime`)
  /// belongs outside domain. Do NOT add `rxdart` to the ban list reflexively —
  /// the omission is deliberate.
  static const Set<String> _bannedExactPackages = <String>{
    'flutter_bloc',
    'bloc',
    'flutter_slidable',
    'flutter_html',
    'flutter_widget_from_html',
    'markdown_widget',
    'skeletonizer',
    'loading_animation_widget',
    'lucide_icons',
    'alchemist',
    'webview_flutter',
    'flutter_tts',
    'google_sign_in',
    'shared_preferences',
    'path_provider',
    'flutter_secure_storage',
    'flutter_cache_manager',
    'cached_network_image',
    'file_picker',
    'flutter_archive',
    'flutter_image_compress',
    'photo_view',
    'url_launcher',
    'share_plus',
    'connectivity_plus',
    'dio',
    'http',
    'shelf',
    'googleapis',
    'googleapis_auth',
  };

  /// Package URI prefixes (the `package:` portion before the first slash)
  /// banned in domain/. Catches every Flutter framework lib, Firebase
  /// plugin, and webview_flutter platform variants.
  static const List<String> _bannedPackagePrefixes = <String>[
    'flutter',
    'firebase_',
    'webview_flutter_',
  ];

  bool get _isInDomain => layout.isIn(filePath, 'domain');

  @override
  void visitImportDirective(ImportDirective node) {
    if (!_isInDomain) {
      return;
    }
    final String? uri = node.uri.stringValue;
    if (uri == null || !uri.startsWith('package:')) {
      return;
    }

    final String pkg = _packageNameOf(uri);
    if (pkg.isEmpty) {
      return;
    }

    final bool banned =
        _bannedExactPackages.contains(pkg) ||
        _bannedPackagePrefixes.any((String p) => pkg == p || pkg.startsWith(p));

    if (banned) {
      report(
        ruleName: 'domain_pure_dart_imports',
        message:
            'package:$pkg is forbidden in domain/. Keep domain pure Dart — '
            'move infrastructure to data/ or presentation/.',
        offset: node.uri.offset,
      );
    }
  }

  /// Extracts `foo` from `package:foo/bar.dart`.
  String _packageNameOf(String uri) {
    final String stripped = uri.substring('package:'.length);
    final int slash = stripped.indexOf('/');
    return slash == -1 ? stripped : stripped.substring(0, slash);
  }
}
