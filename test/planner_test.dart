import 'package:ndk/ndk.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/relay_filter_sync_state.dart';
import 'package:sync_engine_shim_for_ndk/src/planner.dart';
import 'package:test/test.dart';

const relay = 'wss://relay.example.com';
const maxStaleness = Duration(minutes: 5);
const overlapMargin = Duration(minutes: 1);

final now = DateTime.utc(2026, 8, 9, 12);

DateTime ago(Duration duration) => now.subtract(duration);

int seconds(DateTime date) => date.millisecondsSinceEpoch ~/ 1000;

CoverageRange covered(DateTime from, DateTime to, {DateTime? completedAt}) =>
    CoverageRange(from: from, to: to, completedAt: completedAt ?? now);

RelayFilterSyncState stateWith(List<CoverageRange> coverage) =>
    RelayFilterSyncState(
      relayUrl: relay,
      filterFingerprint: 'a1b2c3d4e5f60718',
      coverage: coverage,
    );

List<SyncTask> plan(
  Filter filter, {
  RelayFilterSyncState? state,
  Duration staleness = maxStaleness,
}) => planFilterOnRelay(
  relayUrl: relay,
  filter: filter,
  state: state,
  now: now,
  maxStaleness: staleness,
  overlapMargin: overlapMargin,
);

void main() {
  test('fetches the whole window when nothing is covered', () {
    final since = ago(const Duration(days: 30));

    final tasks = plan(Filter(kinds: [1], since: seconds(since)));

    expect(tasks, hasLength(1));
    expect(tasks.single.relayUrl, relay);
    expect(tasks.single.filter.since, seconds(since.subtract(overlapMargin)));
    expect(tasks.single.filter.until, seconds(now));
  });

  test('reaches back to the epoch when the filter has no since', () {
    final tasks = plan(Filter(kinds: [1]));

    expect(tasks.single.filter.since, lessThan(0));
  });

  test('stops at the filter until when it is in the past', () {
    final since = ago(const Duration(days: 30));
    final until = ago(const Duration(days: 10));

    final tasks = plan(
      Filter(kinds: [1], since: seconds(since), until: seconds(until)),
    );

    expect(tasks.single.filter.until, seconds(until));
  });

  test('plans nothing when the window is already covered and fresh', () {
    final since = ago(const Duration(days: 30));
    final state = stateWith([covered(since, ago(const Duration(seconds: 10)))]);

    final tasks = plan(
      Filter(kinds: [1], since: seconds(since)),
      state: state,
    );

    expect(tasks, isEmpty);
  });

  test('plans the trailing window once it went stale', () {
    final since = ago(const Duration(days: 30));
    final lastFetch = ago(const Duration(hours: 2));
    final state = stateWith([
      covered(since, lastFetch, completedAt: lastFetch),
    ]);

    final tasks = plan(
      Filter(kinds: [1], since: seconds(since)),
      state: state,
    );

    expect(tasks, hasLength(1));
    expect(
      tasks.single.filter.since,
      seconds(
        lastFetch.add(const Duration(seconds: 1)).subtract(overlapMargin),
      ),
    );
    expect(tasks.single.filter.until, seconds(now));
  });

  test('plans nothing when coverage reaches now and is fresh', () {
    final since = ago(const Duration(days: 30));
    final state = stateWith([covered(since, now)]);

    final tasks = plan(
      Filter(kinds: [1], since: seconds(since)),
      state: state,
    );

    expect(tasks, isEmpty);
  });

  test('revisits the recent end even when coverage reaches now', () {
    final since = ago(const Duration(days: 30));
    final state = stateWith([covered(since, now)]);

    final tasks = plan(
      Filter(kinds: [1], since: seconds(since)),
      state: state,
      staleness: Duration.zero,
    );

    expect(
      tasks,
      hasLength(1),
      reason:
          'there is no hole left, yet a refresh '
          'must still go and look',
    );
    expect(tasks.single.filter.since, seconds(now.subtract(overlapMargin)));
    expect(tasks.single.filter.until, seconds(now));
  });

  test('revisits the recent end once the coverage there went stale', () {
    final since = ago(const Duration(days: 30));
    final validatedAt = ago(const Duration(hours: 2));
    final state = stateWith([covered(since, now, completedAt: validatedAt)]);

    final tasks = plan(
      Filter(kinds: [1], since: seconds(since)),
      state: state,
    );

    expect(tasks, hasLength(1));
    expect(tasks.single.filter.until, seconds(now));
  });

  test('plans a fresh trailing window when staleness is zero', () {
    final since = ago(const Duration(days: 30));
    final state = stateWith([covered(since, ago(const Duration(seconds: 10)))]);

    final tasks = plan(
      Filter(kinds: [1], since: seconds(since)),
      state: state,
      staleness: Duration.zero,
    );

    expect(tasks, hasLength(1));
    expect(tasks.single.filter.until, seconds(now));
  });

  test('always plans a hole inside the covered period, however small', () {
    final since = ago(const Duration(days: 30));
    final hole = ago(const Duration(days: 20));
    final state = stateWith([
      covered(since, hole.subtract(const Duration(seconds: 1))),
      covered(hole.add(const Duration(seconds: 1)), ago(Duration.zero)),
    ]);

    final tasks = plan(
      Filter(kinds: [1], since: seconds(since)),
      state: state,
    );

    expect(tasks, hasLength(1));
    expect(tasks.single.filter.since, seconds(hole.subtract(overlapMargin)));
    expect(tasks.single.filter.until, seconds(hole));
  });

  test('reaches two extra days back for gift wraps', () {
    final since = ago(const Duration(days: 30));

    final tasks = plan(Filter(kinds: [giftWrapKind], since: seconds(since)));

    expect(
      tasks.single.filter.since,
      seconds(since.subtract(overlapMargin + giftWrapOverlap)),
    );
  });

  test('keeps the rest of the filter untouched', () {
    final filter = Filter(kinds: [1], authors: const ['abc'], tTags: ['nostr']);

    final tasks = plan(filter);

    expect(tasks.single.filter.kinds, [1]);
    expect(tasks.single.filter.authors, ['abc']);
    expect(tasks.single.filter.tTags, ['nostr']);
  });

  test('drops the limit asked for by the caller', () {
    final tasks = plan(Filter(kinds: [1], limit: 50));

    expect(tasks.single.filter.limit, isNull);
  });

  test('does not touch the filter it was given', () {
    final filter = Filter(kinds: [1]);

    plan(filter);

    expect(filter.since, isNull);
    expect(filter.until, isNull);
  });

  test('plans nothing when until is before since', () {
    final tasks = plan(
      Filter(
        kinds: [1],
        since: seconds(ago(const Duration(days: 1))),
        until: seconds(ago(const Duration(days: 10))),
      ),
    );

    expect(tasks, isEmpty);
  });
}
