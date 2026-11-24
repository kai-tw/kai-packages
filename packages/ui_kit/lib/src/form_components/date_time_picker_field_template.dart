import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'date_time_picker_controller.dart';

/// ============================================================================
/// Field Widgets
/// ============================================================================

/// DateTime picker field
class DateTimePickerField extends DateTimePickerFieldTemplate {
  const DateTimePickerField({
    super.key,
    super.controller,
    super.required,
    super.enabled,
    super.labelText,
    super.helperText,
    super.hintText,
    super.datetimeFormat,
    super.icon,
    super.prefixIcon,
    super.suffixIcon,
    super.initialValue,
    super.firstDate,
    super.lastDate,
    super.onChanged,
    super.onSaved,
    super.validator,
  });

  @override
  State<DateTimePickerFieldTemplate> createState() =>
      _DateTimePickerFieldTemplateState();
}

/// Date picker field
class DatePickerField extends DateTimePickerFieldTemplate {
  const DatePickerField({
    super.key,
    super.controller,
    super.required,
    super.enabled,
    super.labelText,
    super.helperText,
    super.hintText,
    super.datetimeFormat = 'yyyy-MM-dd',
    super.icon,
    super.prefixIcon,
    super.suffixIcon,
    super.initialValue,
    super.firstDate,
    super.lastDate,
    super.onChanged,
    super.onSaved,
    super.validator,
  });

  @override
  State<DateTimePickerFieldTemplate> createState() => _DatePickerFieldState();
}

/// DateTime picker field template.
abstract class DateTimePickerFieldTemplate extends StatefulWidget {
  const DateTimePickerFieldTemplate({
    super.key,
    this.controller,
    this.required = false,
    this.enabled = true,
    this.labelText,
    this.helperText,
    this.hintText,
    this.datetimeFormat = 'yyyy-MM-dd HH:mm',
    this.icon,
    this.prefixIcon,
    this.suffixIcon,
    this.initialValue,
    this.firstDate,
    this.lastDate,
    this.onChanged,
    this.onSaved,
    this.validator,
  });

  final DateTimePickerController? controller;
  final bool required;
  final bool enabled;
  final String? labelText;
  final String? helperText;
  final String? hintText;
  final String datetimeFormat;
  final Widget? icon;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final DateTime? initialValue;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final ValueChanged<DateTime?>? onChanged;
  final FormFieldSetter<DateTime>? onSaved;
  final FormFieldValidator<DateTime>? validator;

  @override
  State<DateTimePickerFieldTemplate> createState();
}

/// ============================================================================
/// State
/// ============================================================================

/// DateTime picker field state.
class _DateTimePickerFieldTemplateState extends _DateTimeState
    with _DateTimePickerMixin {}

/// Date picker field state.
class _DatePickerFieldState extends _DateTimeState with _DatePickerMixin {}

/// DateTime picker field state template.
abstract class _DateTimeState extends State<DateTimePickerFieldTemplate> {
  DateTime? _selectedDateTime;

  @override
  void initState() {
    super.initState();
    _selectedDateTime = widget.controller?.dateTime ?? widget.initialValue;

    // Listen for external changes from the controller
    widget.controller?.addListener(_onControllerChange);
  }

  @override
  void didUpdateWidget(DateTimePickerFieldTemplate oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.initialValue != widget.initialValue) {
      setState(() {
        _selectedDateTime = widget.initialValue;
        widget.controller?.dateTime = widget.initialValue;
      });
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onControllerChange);
      widget.controller?.addListener(_onControllerChange);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FormField<DateTime>(
      enabled: widget.enabled,
      initialValue: _selectedDateTime,
      validator: widget.validator,
      onSaved: widget.onSaved,
      builder: (FormFieldState<DateTime> field) {
        return InkWell(
          onTap: widget.enabled
              ? () async {
                  final DateTime? d = await selectDateTime();

                  if (mounted && d != null) {
                    setState(() {
                      _selectedDateTime = d;
                      field.didChange(d);
                      widget.controller?.value = d;
                      widget.onChanged?.call(d);
                    });
                  }
                }
              : null,
          borderRadius: BorderRadius.circular(16.0),
          child: InputDecorator(
            decoration: InputDecoration(
              enabled: widget.enabled,
              labelText: widget.labelText,
              hintText: widget.hintText,
              helperText: widget.helperText,
              icon: widget.icon,
              prefixIcon: widget.prefixIcon,
              suffixIcon: _buildSuffixIcon(field),
              suffixIconColor: widget.enabled
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
              errorText: field.errorText,
            ),
            isEmpty: _selectedDateTime == null,
            child: Text(
              _selectedDateTime == null
                  ? ''
                  : DateFormat(
                      widget.datetimeFormat,
                    ).format(_selectedDateTime!),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSuffixIcon(FormFieldState<DateTime> field) {
    return widget.suffixIcon ??
        (_selectedDateTime == null || widget.required
            ? const Icon(Icons.calendar_month_rounded)
            : IconButton(
                icon: const Icon(Icons.cleaning_services_rounded),
                tooltip: '清除日期',
                onPressed: widget.enabled
                    ? () {
                        setState(() {
                          _selectedDateTime = null;
                          field.didChange(null);
                          widget.controller?.value = null;
                          widget.onChanged?.call(null);
                        });
                      }
                    : null,
              ));
  }

  Future<DateTime?> selectDateTime();

  void _onControllerChange() {
    if (widget.controller?.value != _selectedDateTime) {
      setState(() {
        _selectedDateTime = widget.controller?.value;
      });
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onControllerChange);
    super.dispose();
  }
}

mixin _DateTimePickerMixin on State<DateTimePickerFieldTemplate> {
  DateTime? _selectedDateTime;

  Future<DateTime?> selectDateTime() async {
    final DateTime firstDate = widget.firstDate ?? DateTime(1900);
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDateTime?.isAfter(firstDate) == true
          ? _selectedDateTime!
          : firstDate,
      firstDate: firstDate,
      lastDate: widget.lastDate ?? DateTime(2100),
    );

    if (pickedDate != null && mounted) {
      final TimeOfDay? pickedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.now(),
      );

      if (pickedTime != null) {
        return DateTime(
          pickedDate.year,
          pickedDate.month,
          pickedDate.day,
          pickedTime.hour,
          pickedTime.minute,
        );
      }
    }

    return null;
  }
}

mixin _DatePickerMixin on State<DateTimePickerFieldTemplate> {
  DateTime? _selectedDateTime;

  Future<DateTime?> selectDateTime() async {
    final DateTime firstDate = widget.firstDate ?? DateTime(1900);
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDateTime?.isAfter(firstDate) == true
          ? _selectedDateTime!
          : firstDate,
      firstDate: firstDate,
      lastDate: widget.lastDate ?? DateTime(2100),
    );

    if (pickedDate != null) {
      return DateTime(pickedDate.year, pickedDate.month, pickedDate.day);
    }

    return null;
  }
}
