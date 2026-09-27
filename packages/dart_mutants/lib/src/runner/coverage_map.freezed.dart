// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'coverage_map.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$CoverageMapJson {

 List<String> get tests;/// file -> line -> indexes into [tests].
 Map<String, Map<int, List<int>>> get files;
/// Create a copy of CoverageMapJson
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CoverageMapJsonCopyWith<CoverageMapJson> get copyWith => _$CoverageMapJsonCopyWithImpl<CoverageMapJson>(this as CoverageMapJson, _$identity);

  /// Serializes this CoverageMapJson to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CoverageMapJson&&const DeepCollectionEquality().equals(other.tests, tests)&&const DeepCollectionEquality().equals(other.files, files));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(tests),const DeepCollectionEquality().hash(files));

@override
String toString() {
  return 'CoverageMapJson(tests: $tests, files: $files)';
}


}

/// @nodoc
abstract mixin class $CoverageMapJsonCopyWith<$Res>  {
  factory $CoverageMapJsonCopyWith(CoverageMapJson value, $Res Function(CoverageMapJson) _then) = _$CoverageMapJsonCopyWithImpl;
@useResult
$Res call({
 List<String> tests, Map<String, Map<int, List<int>>> files
});




}
/// @nodoc
class _$CoverageMapJsonCopyWithImpl<$Res>
    implements $CoverageMapJsonCopyWith<$Res> {
  _$CoverageMapJsonCopyWithImpl(this._self, this._then);

  final CoverageMapJson _self;
  final $Res Function(CoverageMapJson) _then;

/// Create a copy of CoverageMapJson
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? tests = null,Object? files = null,}) {
  return _then(_self.copyWith(
tests: null == tests ? _self.tests : tests // ignore: cast_nullable_to_non_nullable
as List<String>,files: null == files ? _self.files : files // ignore: cast_nullable_to_non_nullable
as Map<String, Map<int, List<int>>>,
  ));
}

}


/// Adds pattern-matching-related methods to [CoverageMapJson].
extension CoverageMapJsonPatterns on CoverageMapJson {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _CoverageMapJson value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _CoverageMapJson() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _CoverageMapJson value)  $default,){
final _that = this;
switch (_that) {
case _CoverageMapJson():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _CoverageMapJson value)?  $default,){
final _that = this;
switch (_that) {
case _CoverageMapJson() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<String> tests,  Map<String, Map<int, List<int>>> files)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _CoverageMapJson() when $default != null:
return $default(_that.tests,_that.files);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<String> tests,  Map<String, Map<int, List<int>>> files)  $default,) {final _that = this;
switch (_that) {
case _CoverageMapJson():
return $default(_that.tests,_that.files);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<String> tests,  Map<String, Map<int, List<int>>> files)?  $default,) {final _that = this;
switch (_that) {
case _CoverageMapJson() when $default != null:
return $default(_that.tests,_that.files);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _CoverageMapJson implements CoverageMapJson {
  const _CoverageMapJson({required final  List<String> tests, required final  Map<String, Map<int, List<int>>> files}): _tests = tests,_files = files;
  factory _CoverageMapJson.fromJson(Map<String, dynamic> json) => _$CoverageMapJsonFromJson(json);

 final  List<String> _tests;
@override List<String> get tests {
  if (_tests is EqualUnmodifiableListView) return _tests;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_tests);
}

/// file -> line -> indexes into [tests].
 final  Map<String, Map<int, List<int>>> _files;
/// file -> line -> indexes into [tests].
@override Map<String, Map<int, List<int>>> get files {
  if (_files is EqualUnmodifiableMapView) return _files;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_files);
}


/// Create a copy of CoverageMapJson
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$CoverageMapJsonCopyWith<_CoverageMapJson> get copyWith => __$CoverageMapJsonCopyWithImpl<_CoverageMapJson>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$CoverageMapJsonToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _CoverageMapJson&&const DeepCollectionEquality().equals(other._tests, _tests)&&const DeepCollectionEquality().equals(other._files, _files));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_tests),const DeepCollectionEquality().hash(_files));

@override
String toString() {
  return 'CoverageMapJson(tests: $tests, files: $files)';
}


}

/// @nodoc
abstract mixin class _$CoverageMapJsonCopyWith<$Res> implements $CoverageMapJsonCopyWith<$Res> {
  factory _$CoverageMapJsonCopyWith(_CoverageMapJson value, $Res Function(_CoverageMapJson) _then) = __$CoverageMapJsonCopyWithImpl;
@override @useResult
$Res call({
 List<String> tests, Map<String, Map<int, List<int>>> files
});




}
/// @nodoc
class __$CoverageMapJsonCopyWithImpl<$Res>
    implements _$CoverageMapJsonCopyWith<$Res> {
  __$CoverageMapJsonCopyWithImpl(this._self, this._then);

  final _CoverageMapJson _self;
  final $Res Function(_CoverageMapJson) _then;

/// Create a copy of CoverageMapJson
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? tests = null,Object? files = null,}) {
  return _then(_CoverageMapJson(
tests: null == tests ? _self._tests : tests // ignore: cast_nullable_to_non_nullable
as List<String>,files: null == files ? _self._files : files // ignore: cast_nullable_to_non_nullable
as Map<String, Map<int, List<int>>>,
  ));
}


}

// dart format on
