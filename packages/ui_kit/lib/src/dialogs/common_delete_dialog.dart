import 'package:flutter/material.dart';

/// The standard confirm-then-delete dialog: a destructive action gated by a
/// confirmation, with the delete button itself managing [onDelete]'s async
/// lifecycle — a spinner while it runs, and on failure the dialog stays open
/// with its buttons live again so the caller can decide what to show.
///
/// **Handle failure INSIDE `onDelete`. There is no outer place to catch it.**
///
/// The dialog does not catch — it knows nothing about an arbitrary callback's
/// exception types, so the only report it could produce was `toString()` in a
/// text field, away from the error handling that knows what failed. But the
/// escape route is not what it looks like: the delete button invokes `onDelete`
/// fire-and-forget, and `show` returns the *dialog route's* future, not the
/// callback's. So a `try` around `show` compiles, raises no lint, and catches
/// nothing — the exception becomes an unhandled async error and reaches the
/// zone handler, which in most apps means it is logged and the user is told
/// nothing.
///
/// All copy (`title`, `content`, `cancelLabel`, `deleteLabel`) is required —
/// see the package README §Text ownership.
///
/// [confirmPhrase], if set, gates the delete button behind a text field that
/// must match it exactly — for actions destructive enough that a second tap
/// isn't enough friction. [confirmFieldHint] is then required too (the same
/// text-ownership rule extends to it — the package cannot phrase "type X to
/// confirm" itself without picking a language).
class CommonDeleteDialog extends StatefulWidget {
  const CommonDeleteDialog({
    super.key,
    required this.title,
    required this.content,
    required this.cancelLabel,
    required this.deleteLabel,
    this.deleteIcon = Icons.delete_rounded,
    required this.onDelete,
    this.confirmPhrase,
    this.confirmFieldHint,
  }) : assert(
         confirmPhrase == null || confirmFieldHint != null,
         'confirmFieldHint is required when confirmPhrase is set',
       );

  final String title;
  final String content;
  final String cancelLabel;
  final String deleteLabel;
  final IconData deleteIcon;
  final Future<void> Function() onDelete;
  final String? confirmPhrase;
  final String? confirmFieldHint;

  @override
  State<CommonDeleteDialog> createState() => _CommonDeleteDialogState();

  static Future<void> show(
    BuildContext context, {
    required String title,
    required String content,
    required String cancelLabel,
    required String deleteLabel,
    IconData deleteIcon = Icons.delete_rounded,
    required Future<void> Function() onDelete,
    String? confirmPhrase,
    String? confirmFieldHint,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => CommonDeleteDialog(
        title: title,
        content: content,
        cancelLabel: cancelLabel,
        deleteLabel: deleteLabel,
        deleteIcon: deleteIcon,
        onDelete: onDelete,
        confirmPhrase: confirmPhrase,
        confirmFieldHint: confirmFieldHint,
      ),
    );
  }
}

class _CommonDeleteDialogState extends State<CommonDeleteDialog> {
  bool _isLoading = false;
  final TextEditingController _confirmController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _confirmController.addListener(_onConfirmTextChanged);
  }

  @override
  void dispose() {
    _confirmController.removeListener(_onConfirmTextChanged);
    _confirmController.dispose();
    super.dispose();
  }

  void _onConfirmTextChanged() {
    setState(() {});
  }

  bool get _isConfirmSatisfied =>
      widget.confirmPhrase == null ||
      _confirmController.text == widget.confirmPhrase;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isLoading,
      child: AlertDialog(
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(widget.content),
            if (widget.confirmPhrase != null) ...<Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: TextField(
                  controller: _confirmController,
                  enabled: !_isLoading,
                  decoration: InputDecoration(
                    hintText: widget.confirmFieldHint,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton.icon(
            onPressed: _isLoading ? null : _onCancel,
            icon: const Icon(Icons.close_rounded),
            label: Text(widget.cancelLabel),
          ),
          FilledButton.icon(
            onPressed: _isLoading || !_isConfirmSatisfied ? null : _onDelete,
            icon: _isLoading
                ? const SizedBox(
                    width: 16.0,
                    height: 16.0,
                    child: CircularProgressIndicator(strokeWidth: 2.0),
                  )
                : Icon(widget.deleteIcon),
            label: Text(widget.deleteLabel),
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.onError,
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onDelete() async {
    setState(() {
      _isLoading = true;
    });

    // No catch: this dialog cannot say anything useful about an arbitrary
    // callback's exception, and catching one here only moved the report away
    // from the handler that knows what failed, into a text field rendering
    // toString().
    //
    // Where the exception actually goes: onPressed invokes this method
    // fire-and-forget, so nothing awaits the future it returns. The exception
    // escapes to the zone handler — NOT to whoever called `show`, whose future
    // belongs to the dialog route. That is why the contract is "handle it
    // inside onDelete": there is no outer frame that could.
    //
    // The finally is not a catch: it lets the failure past untouched and only
    // clears the loading state, so the dialog does not wedge on a spinner with
    // its buttons disabled.
    try {
      await widget.onDelete();

      if (mounted) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _onCancel() {
    Navigator.of(context).pop();
  }
}
