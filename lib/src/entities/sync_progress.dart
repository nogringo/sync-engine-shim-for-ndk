/// A page that just landed, as a sign of life during a long walk.
class SyncProgress {
  const SyncProgress({
    required this.relayUrl,
    required this.filterFingerprint,
    required this.from,
    required this.to,
    required this.eventCount,
  });

  final String relayUrl;
  final String filterFingerprint;

  /// The period this page closed. A walk moves from the recent end towards the
  /// old one, so successive pages report older and older periods.
  final DateTime from;
  final DateTime to;

  /// What the relay returned for this page. Counts duplicates across relays:
  /// it is a rate, not an inventory.
  final int eventCount;

  @override
  String toString() =>
      'SyncProgress($relayUrl, $from - $to, $eventCount events)';
}
