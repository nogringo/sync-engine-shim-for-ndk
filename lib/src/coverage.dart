import 'package:sync_engine_shim_for_ndk/src/entities/relay_filter_sync_state.dart';

/// Nostr timestamps have a one second grain, so ranges one second apart touch.
const _grain = Duration(seconds: 1);

/// Inserts [range] into [coverage] and returns a normalised list: sorted,
/// disjoint, with [range] winning over whatever it overlaps.
///
/// Contiguous ranges are merged only when they share a completedAt, so a merge
/// never claims freshness the coverage does not have. A paginated pass
/// therefore has to stamp all its pages with the same timestamp, otherwise
/// every page stays its own range.
List<CoverageRange> addRange(
  List<CoverageRange> coverage,
  CoverageRange range,
) {
  final result = <CoverageRange>[];

  for (final existing in coverage) {
    if (existing.to.isBefore(range.from) || existing.from.isAfter(range.to)) {
      result.add(existing);
      continue;
    }
    if (existing.from.isBefore(range.from)) {
      result.add(
        CoverageRange(
          from: existing.from,
          to: range.from.subtract(_grain),
          completedAt: existing.completedAt,
        ),
      );
    }
    if (existing.to.isAfter(range.to)) {
      result.add(
        CoverageRange(
          from: range.to.add(_grain),
          to: existing.to,
          completedAt: existing.completedAt,
        ),
      );
    }
  }

  result
    ..add(range)
    ..sort((a, b) => a.from.compareTo(b.from));

  return _merged(result);
}

/// Periods between [from] and [to] that [coverage] does not cover, in order.
/// Expects a normalised [coverage].
List<({DateTime from, DateTime to})> findGaps(
  List<CoverageRange> coverage, {
  required DateTime from,
  required DateTime to,
}) {
  final gaps = <({DateTime from, DateTime to})>[];
  var cursor = from;

  for (final range in coverage) {
    if (range.to.isBefore(cursor)) continue;
    if (range.from.isAfter(to)) break;

    if (range.from.isAfter(cursor)) {
      gaps.add((from: cursor, to: _min(range.from.subtract(_grain), to)));
    }
    cursor = range.to.add(_grain);
  }

  if (!cursor.isAfter(to)) {
    gaps.add((from: cursor, to: to));
  }

  return gaps;
}

List<CoverageRange> _merged(List<CoverageRange> sorted) {
  final merged = <CoverageRange>[];

  for (final range in sorted) {
    final previous = merged.isEmpty ? null : merged.last;
    final touches =
        previous != null && !range.from.isAfter(previous.to.add(_grain));

    if (touches && previous.completedAt == range.completedAt) {
      merged[merged.length - 1] = CoverageRange(
        from: previous.from,
        to: _max(previous.to, range.to),
        completedAt: previous.completedAt,
      );
    } else {
      merged.add(range);
    }
  }

  return merged;
}

DateTime _min(DateTime a, DateTime b) => a.isBefore(b) ? a : b;

DateTime _max(DateTime a, DateTime b) => a.isAfter(b) ? a : b;
