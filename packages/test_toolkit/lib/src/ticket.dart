/// A place in a `TicketQueue`, held until [leave].
class Ticket {
  /// Made by `TicketQueue.take`; [_leave] gives the place up.
  Ticket(this.number, this._leave);

  final int number;
  final void Function() _leave;
  bool _left = false;

  /// Leaves the line. Later calls do nothing: a second leave would close
  /// the ticket's file again.
  void leave() {
    if (_left) {
      return;
    }
    _left = true;
    _leave();
  }
}
