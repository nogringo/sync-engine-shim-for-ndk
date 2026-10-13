/// A request's relays could not be resolved, so its pass did not run: a list
/// it reads was never fetched, and no relay answered for it this time.
class SyncRelaysUnavailable implements Exception {
  const SyncRelaysUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'SyncRelaysUnavailable: $reason';
}
