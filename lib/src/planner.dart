import 'package:ndk/ndk.dart';
import 'package:sync_engine_shim_for_ndk/src/coverage.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/relay_filter_sync_state.dart';

/// NIP-59 gift wrap.
const giftWrapKind = 1059;

/// NIP-59 randomises a gift wrap's created_at up to two days into the past, so
/// a window on [giftWrapKind] reaches that much further back or those events
/// are missed for good.
const giftWrapOverlap = Duration(days: 2);

final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// One window to fetch from one relay. [filter] carries the window in its
/// `since` and `until`.
class SyncTask {
  const SyncTask({required this.relayUrl, required this.filter});

  final String relayUrl;
  final Filter filter;

  @override
  String toString() => 'SyncTask($relayUrl, ${filter.since} - ${filter.until})';
}

/// Windows still to fetch for [filter] on [relayUrl], given what [state]
/// already covers.
///
/// Holes inside the covered period are always worth a task. The recent end is
/// different: it is revisited only once the coverage there is older than
/// [maxStaleness], measured on when that coverage was last validated rather
/// than on how wide the remaining hole is. Coverage reaching all the way to
/// [now] leaves no hole at all, yet still goes stale. Passing [Duration.zero]
/// therefore expresses the pull to refresh gesture, and always revisits the
/// recent end.
///
/// Windows reach [overlapMargin] further back than strictly needed, to absorb
/// clock skew and late deliveries. That deliberately goes past the filter's
/// own `since`, which is what makes gift wraps reachable at all.
///
/// The filter's `limit` is dropped: it is excluded from the fingerprint, so
/// honouring it would let a capped request mark a window as covered and leave
/// an uncapped one believing there is nothing left to fetch.
List<SyncTask> planFilterOnRelay({
  required String relayUrl,
  required Filter filter,
  required RelayFilterSyncState? state,
  required DateTime now,
  required Duration maxStaleness,
  required Duration overlapMargin,
}) {
  final from = _dateFromSeconds(filter.since) ?? _epoch;
  final until = _dateFromSeconds(filter.until);
  final to = until == null || until.isAfter(now) ? now : until;

  if (to.isBefore(from)) return const [];

  final overlap = overlapMargin + _giftWrapMargin(filter);
  final coverage = state?.coverage ?? const <CoverageRange>[];
  final fresh = _isFresh(coverage, now: now, maxStaleness: maxStaleness);

  final tasks = <SyncTask>[];
  var reachesTheEnd = false;

  for (final gap in findGaps(coverage, from: from, to: to)) {
    if (gap.to == to) {
      reachesTheEnd = true;
      if (fresh) continue;
    }
    tasks.add(_task(relayUrl, filter, gap.from.subtract(overlap), gap.to));
  }

  // Coverage running all the way to [to] leaves no hole to widen, so the
  // recent end has to be revisited on its own once it went stale.
  if (!reachesTheEnd && !fresh) {
    tasks.add(_task(relayUrl, filter, to.subtract(overlap), to));
  }

  return tasks;
}

SyncTask _task(String relayUrl, Filter filter, DateTime since, DateTime until) {
  // Reaching under the epoch means asking for everything, which a filter says
  // by leaving `since` out rather than by carrying a negative timestamp.
  final seconds = _secondsFromDate(since);

  return SyncTask(
    relayUrl: relayUrl,
    filter: filter.clone()
      ..since = seconds > 0 ? seconds : null
      ..until = _secondsFromDate(until)
      ..limit = null,
  );
}

/// How long ago the most recent coverage was validated, as opposed to how far
/// it reaches: a window fetched an hour ago is stale even if it was fetched up
/// to the second.
bool _isFresh(
  List<CoverageRange> coverage, {
  required DateTime now,
  required Duration maxStaleness,
}) {
  if (maxStaleness == Duration.zero || coverage.isEmpty) return false;

  var validatedAt = coverage.first.completedAt;
  for (final range in coverage) {
    if (range.completedAt.isAfter(validatedAt)) validatedAt = range.completedAt;
  }

  return now.difference(validatedAt) < maxStaleness;
}

Duration _giftWrapMargin(Filter filter) =>
    (filter.kinds ?? const []).contains(giftWrapKind)
    ? giftWrapOverlap
    : Duration.zero;

DateTime? _dateFromSeconds(int? seconds) => seconds == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

int _secondsFromDate(DateTime date) => date.millisecondsSinceEpoch ~/ 1000;
