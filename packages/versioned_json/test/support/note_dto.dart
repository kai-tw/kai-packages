import 'package:json_annotation/json_annotation.dart';
import 'package:versioned_json/versioned_json.dart';

/// The colour a note is shown in: the enum a stored code names.
enum NoteColour { plain, yellow }

/// A note at version 3 of `NoteSchema`'s format.
class NoteDto implements VersionedJsonDto {
  const NoteDto({
    required this.payload,
    this.colour = NoteColour.plain,
    this.steps = const <String>[],
  });

  /// Throws a [CheckedFromJsonException] when `payload` is no string, as a
  /// `checked: true` generated codec does — the stand-in for a field that
  /// fails to parse.
  factory NoteDto.fromJson(Map<String, dynamic> json) {
    final Object? payload = json['payload'];
    if (payload is! String) {
      throw CheckedFromJsonException(json, 'payload', 'NoteDto', null);
    }
    return NoteDto(
      payload: payload,
      colour: NoteColour.values.byName(
        json['colour'] as String? ?? NoteColour.plain.name,
      ),
      steps: <String>[...json['steps'] as List<dynamic>? ?? <dynamic>[]],
    );
  }

  final String payload;
  final NoteColour colour;

  /// The migration steps the stored document went through, in order.
  final List<String> steps;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'payload': payload,
    'colour': colour.name,
    'steps': steps,
  };
}
