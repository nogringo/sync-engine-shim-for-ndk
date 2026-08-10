import 'package:ndk/ndk.dart';
import 'package:ndk/shared/helpers/relay_helper.dart';
import 'package:sync_engine_shim_for_ndk/src/coverage.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/relay_filter_sync_state.dart';
import 'package:sync_engine_shim_for_ndk/src/filter_fingerprint.dart';
import 'package:sync_engine_shim_for_ndk/src/planner.dart';
import 'package:sync_engine_shim_for_ndk/src/store/sync_store.dart';

/// How a task ended. Giving up on purpose is not a failure: it must not count
/// against the relay, which never did anything wrong.
enum TaskOutcome { answered, unreachable, cancelled }

/// Runs planned tasks against the relays and records the ground covered.
/// Events land in the NDK cache, this only keeps track of what was walked.
class TaskRunner {
  TaskRunner({
    required this.ndk,
    required this.store,
    this.pageLimit = 500,
    this.timeout = const Duration(seconds: 10),
  });

  final Ndk ndk;
  final SyncStore store;

  /// Caps the size of a single response. It says nothing about the end of a
  /// window: relays enforce their own maximum, so a short page is no proof
  /// that the relay ran out of events.
  final int pageLimit;

  final Duration timeout;

  /// Walks [task]'s window from the recent end towards the old one, recording
  /// coverage page by page so an interrupted run keeps what it earned.
  ///
  /// An empty page is the only signal that the relay has nothing left, and it
  /// is what lets a window without a `since` be closed down to the epoch.
  ///
  /// Every page shares [startedAt] as its completedAt, which is what lets the
  /// pages merge back into a single range.
  ///
  /// [isCancelled] is read between pages, which is the only place a walk can
  /// be dropped without losing the page in flight. A long backfill therefore
  /// stops within one page rather than running on after the caller left.
  ///
  /// Nothing is marked as covered when the relay could not be reached.
  Future<TaskOutcome> run(
    SyncTask task, {
    String? authPubkey,
    required DateTime startedAt,
    bool Function()? isCancelled,
  }) async {
    final fingerprint = filterFingerprint(task.filter);
    // No `since` on the task means the window opens at the epoch.
    final since = task.filter.since ?? 0;
    var until = task.filter.until!;

    while (true) {
      if (isCancelled?.call() ?? false) return TaskOutcome.cancelled;

      var timedOut = false;
      final events = await ndk.requests
          .query(
            filter: task.filter.clone()
              ..until = until
              ..limit = pageLimit,
            explicitRelays: [task.relayUrl],
            cacheRead: false,
            cacheWrite: true,
            timeout: timeout,
            timeoutCallback: () => timedOut = true,
          )
          .future;

      if (timedOut || !_isReachable(task.relayUrl)) {
        await _record(
          relayUrl: task.relayUrl,
          fingerprint: fingerprint,
          authPubkey: authPubkey,
          startedAt: startedAt,
        );
        return TaskOutcome.unreachable;
      }

      if (events.isEmpty) {
        await _record(
          relayUrl: task.relayUrl,
          fingerprint: fingerprint,
          authPubkey: authPubkey,
          startedAt: startedAt,
          covered: (from: since, to: until),
        );
        return TaskOutcome.answered;
      }

      final oldest = events.map((event) => event.createdAt).reduce(_min);
      final int walkedFrom;

      if (oldest >= until) {
        // A single second cannot be paginated any finer, so it is taken as
        // walked rather than left as a hole retried forever.
        walkedFrom = until;
      } else if (oldest <= since) {
        walkedFrom = since;
      } else {
        walkedFrom = oldest + 1;
      }

      await _record(
        relayUrl: task.relayUrl,
        fingerprint: fingerprint,
        authPubkey: authPubkey,
        startedAt: startedAt,
        covered: (from: walkedFrom, to: until),
      );

      if (walkedFrom <= since) return TaskOutcome.answered;
      until = walkedFrom - 1;
    }
  }

  /// NDK never says which relay sent the EOSE, so an exhausted relay and a
  /// silent one look alike. Two partial signals cover each other: a timeout
  /// catches a relay that answers nothing, and connectivity catches a request
  /// that was dropped before reaching a socket, which ends without a timeout.
  bool _isReachable(String relayUrl) =>
      ndk.relays.isRelayConnected(cleanRelayUrl(relayUrl) ?? relayUrl);

  Future<void> _record({
    required String relayUrl,
    required String fingerprint,
    required String? authPubkey,
    required DateTime startedAt,
    ({int from, int to})? covered,
  }) async {
    final previous = await store.readSyncState(
      relayUrl: relayUrl,
      filterFingerprint: fingerprint,
      authPubkey: authPubkey,
    );
    final coverage = previous?.coverage ?? const <CoverageRange>[];

    await store.writeSyncState(
      RelayFilterSyncState(
        relayUrl: relayUrl,
        filterFingerprint: fingerprint,
        authPubkey: authPubkey,
        coverage: covered == null
            ? coverage
            : addRange(coverage, _rangeOf(covered, startedAt)),
        lastAttemptAt: startedAt,
      ),
    );
  }

  CoverageRange _rangeOf(({int from, int to}) covered, DateTime completedAt) =>
      CoverageRange(
        from: _dateFromSeconds(covered.from),
        to: _dateFromSeconds(covered.to),
        completedAt: completedAt,
      );

  DateTime _dateFromSeconds(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

int _min(int a, int b) => a < b ? a : b;
