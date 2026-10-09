/// Typed, enum-keyed persistence for app preferences.
///
/// Two symbols:
///
/// - [PreferenceRepository] — the observable, typed seam a feature-level
///   preference repository implements.
/// - [PreferenceLocalDataSource] (+ [SharedPreferencesLocalDataSource]) — the
///   generic engine underneath: primitives in, primitives out, keyed by an
///   app-owned enum instead of a raw string.
///
/// This package does not know about an app's preference *shapes* — no
/// entities, no keys enum, no DI wiring. It owns exactly the part that was
/// identical across every one of them.
library;

export 'src/data/preference_local_data_source.dart';
export 'src/data/shared_preferences_local_data_source.dart';
export 'src/domain/preference_repository.dart';
