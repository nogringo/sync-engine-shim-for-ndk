import 'package:ndk/ndk.dart';
import 'package:ndk/shared/helpers/relay_helper.dart';
import 'package:sync_engine_shim_for_ndk/src/coverage.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/relay_filter_sync_state.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/sync_progress.dart';
import 'package:sync_engine_shim_for_ndk/src/filter_fingerprint.dart';
import 'package:sync_engine_shim_for_ndk/src/planner.dart';
import 'package:sync_engine_shim_for_ndk/src/store/sync_store.dart';

/// How a task ended. Giving up on purpose is not a failure: it must not count
/// against the relay, which never did anything wrong.
enum TaskOutcome {
  answered,

  /// the relay ended the request with a CLOSED: it is up and answering, only
  /// not this request, so waiting changes nothing until the request does
  refused,

  unreachable,
  cancelled,
}

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
  /// Only an EOSE records coverage. Anything else, a CLOSED, a dead socket or
  /// a timeout, leaves the window as it was: a relay that refuses a request
  /// returns no events either, and would otherwise pass for an exhausted one.
  ///
  /// Under an EOSE an empty page is the signal that the relay has nothing
  /// left, and it is what lets a window without a `since` be closed down to
  /// the epoch.
  ///
  /// Every page shares [startedAt] as its completedAt, which is what lets the
  /// pages merge back into a single range.
  ///
  /// [isCancelled] is read between pages, which is the only place a walk can
  /// be dropped without losing the page in flight. A long backfill therefore
  /// stops within one page rather than running on after the caller left.
  ///
  /// [auth] is both what goes on the wire and what the coverage is filed under,
  /// so a window can only be recorded against the identity that read it. It is
  /// never null: a request that says nothing to ndk still authenticates as the
  /// logged account once a relay refuses it.
  Future<TaskOutcome> run(
    SyncTask task, {
    AuthPolicy auth = const AuthPolicy.never(),
    required DateTime startedAt,
    bool Function()? isCancelled,
    void Function(SyncProgress)? onProgress,
  }) async {
    final authPubkey = auth.account?.pubkey;
    final fingerprint = filterFingerprint(task.filter);
    // No `since` on the task means the window opens at the epoch.
    final since = task.filter.since ?? 0;
    var until = task.filter.until!;

    while (true) {
      if (isCancelled?.call() ?? false) return TaskOutcome.cancelled;

      final response = ndk.requests.query(
        filter: task.filter.clone()
          ..until = until
          ..limit = pageLimit,
        explicitRelays: [task.relayUrl],
        cacheRead: false,
        cacheWrite: true,
        timeout: timeout,
        auth: auth,
      );

      final events = await response.future;
      final outcomes = await response.relayOutcomesDone;
      // The map is keyed by normalised url, and a relay nothing reached has no
      // entry at all rather than a status saying so.
      final status =
          outcomes[cleanRelayUrl(task.relayUrl) ?? task.relayUrl]?.status;

      if (status != RelayRequestStatus.eose) {
        await _record(
          relayUrl: task.relayUrl,
          fingerprint: fingerprint,
          authPubkey: authPubkey,
          startedAt: startedAt,
        );

        return status == RelayRequestStatus.closed
            ? TaskOutcome.refused
            : TaskOutcome.unreachable;
      }

      if (events.isEmpty) {
        await _record(
          relayUrl: task.relayUrl,
          fingerprint: fingerprint,
          authPubkey: authPubkey,
          startedAt: startedAt,
          covered: (from: since, to: until),
        );
        _report(onProgress, task, fingerprint, (from: since, to: until), 0);
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
      _report(onProgress, task, fingerprint, (
        from: walkedFrom,
        to: until,
      ), events.length);

      if (walkedFrom <= since) return TaskOutcome.answered;
      until = walkedFrom - 1;
    }
  }

  void _report(
    void Function(SyncProgress)? onProgress,
    SyncTask task,
    String fingerprint,
    ({int from, int to}) closed,
    int eventCount,
  ) => onProgress?.call(
    SyncProgress(
      relayUrl: task.relayUrl,
      filterFingerprint: fingerprint,
      from: _dateFromSeconds(closed.from),
      to: _dateFromSeconds(closed.to),
      eventCount: eventCount,
    ),
  );

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
