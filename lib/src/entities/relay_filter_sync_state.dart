/// What the engine knows about one (relay, filter) pair.
class RelayFilterSyncState {
  const RelayFilterSyncState({
    required this.relayUrl,
    required this.filterFingerprint,
    this.authPubkey,
    this.coverage = const [],
    this.lastAttemptAt,
  });

  final String relayUrl;

  /// Identity of the logical filter. Pagination fields, which change on every
  /// request, are excluded.
  final String filterFingerprint;

  final String? authPubkey;

  /// Time ranges already fetched from this relay for this filter. Normalised,
  /// not an append-only log: sorted, disjoint, no period listed twice. A new
  /// range splits or replaces the ones it overlaps, and adjacent ranges may be
  /// merged to fight fragmentation.
  final List<CoverageRange> coverage;

  final DateTime? lastAttemptAt;
}

class CoverageRange {
  const CoverageRange({
    required this.from,
    required this.to,
    required this.completedAt,
  });

  final DateTime from;
  final DateTime to;

  /// Last known validation of this range. Merging two ranges keeps the oldest
  /// one, so the merge never claims freshness it does not have.
  final DateTime completedAt;
}
