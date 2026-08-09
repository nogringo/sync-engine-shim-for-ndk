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
/// Holes inside the covered period are always worth a task. The hole at the
/// end, which grows by itself as time passes, only becomes one once it is
/// older than [maxStaleness]. Passing [Duration.zero] therefore expresses the
/// pull to refresh gesture.
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

  return [
    for (final gap in findGaps(state?.coverage ?? const [], from: from, to: to))
      if (!_isFreshEnough(gap, to: to, maxStaleness: maxStaleness))
        SyncTask(
          relayUrl: relayUrl,
          filter: filter.clone()
            ..since = _secondsFromDate(gap.from.subtract(overlap))
            ..until = _secondsFromDate(gap.to)
            ..limit = null,
        ),
  ];
}

/// The trailing hole is the one that widens on its own, so it is the only one
/// [maxStaleness] applies to.
bool _isFreshEnough(
  ({DateTime from, DateTime to}) gap, {
  required DateTime to,
  required Duration maxStaleness,
}) => gap.to == to && gap.to.difference(gap.from) < maxStaleness;

Duration _giftWrapMargin(Filter filter) =>
    (filter.kinds ?? const []).contains(giftWrapKind)
    ? giftWrapOverlap
    : Duration.zero;

DateTime? _dateFromSeconds(int? seconds) => seconds == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

int _secondsFromDate(DateTime date) => date.millisecondsSinceEpoch ~/ 1000;
