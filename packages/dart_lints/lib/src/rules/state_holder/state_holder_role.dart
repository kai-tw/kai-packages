/// One kind of state holder: the framework base that makes a class one, the
/// word its name ends in, and where its state type sits among the base's type
/// arguments.
///
/// `Cubit<S>` holds its state in argument 0, `Bloc<E, S>` in argument 1. A
/// base whose state need not be a named type — a Riverpod `Notifier<int>` —
/// leaves [stateTypeArgument] unset, and its state type is not checked.
class StateHolderRole {
  const StateHolderRole({
    required this.base,
    required this.suffix,
    this.stateTypeArgument,
  });

  factory StateHolderRole.fromMap(Map<String, Object?> map) => StateHolderRole(
    base: map['base']! as String,
    suffix: map['suffix']! as String,
    stateTypeArgument: map['stateTypeArgument'] as int?,
  );

  /// The framework class, matched by name.
  final String base;

  /// The word a subtype's name ends in.
  final String suffix;

  /// The index of the state type among [base]'s type arguments, or `null`
  /// when the state type is not checked.
  final int? stateTypeArgument;
}
