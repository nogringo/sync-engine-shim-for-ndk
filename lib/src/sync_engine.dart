import 'dart:async';
import 'dart:collection';

import 'package:ndk/ndk.dart';
import 'package:ndk/shared/helpers/relay_helper.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sembast/sembast.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/relay_filter_sync_state.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/sync_engine_status.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/sync_handle.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/sync_request.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/sync_request_status.dart';
import 'package:sync_engine_shim_for_ndk/src/filter_fingerprint.dart';
import 'package:sync_engine_shim_for_ndk/src/planner.dart';
import 'package:sync_engine_shim_for_ndk/src/store/sync_store.dart';
import 'package:sync_engine_shim_for_ndk/src/task_runner.dart';

/// Downward sync only: the engine fills the NDK cache, it never broadcasts.
/// Callers read events from the NDK cache, not from this API.
///
/// Relays work in parallel, one query at a time each. A slow relay never holds
/// back a fast one, and a relay wanted by several requests still sees a single
/// query at a time.
class SyncEngine {
  SyncEngine(
    this.ndk, {
    required Database db,
    this.maxStaleness = const Duration(minutes: 5),
    this.overlapMargin = const Duration(days: 1),
  }) : store = SyncStore(db: db) {
    _runner = TaskRunner(ndk: ndk, store: store);
  }

  final Ndk ndk;
  final SyncStore store;

  /// How old coverage may get before [ensure] goes back to the relays.
  final Duration maxStaleness;

  /// How far back a new pass reaches beyond existing coverage, to absorb clock
  /// skew and late deliveries.
  final Duration overlapMargin;

  late final TaskRunner _runner;

  final _engineStatus = BehaviorSubject<SyncEngineStatus>.seeded(
    const SyncEngineStatus(phase: SyncEnginePhase.stopped),
  );
  final _registrations = <String, _Registration>{};
  final _queues = <String, _RelayQueue>{};

  var _started = false;

  /// Starts processing registered requests.
  void start() {
    if (_started) return;
    _started = true;

    for (final id in _registrations.keys.toList()) {
      unawaited(_sync(id));
    }
    _publishEngineStatus();
  }

  /// Stops taking on new work and waits for what is in flight. Handles and
  /// persisted state survive.
  Future<void> stop() async {
    _started = false;
    await _inFlight();
    _publishEngineStatus();
  }

  /// Keeps [request] available in the cache: the engine fills whatever is
  /// missing, down to each filter's `since`. Cheap to call repeatedly, it only
  /// goes to the relays when coverage is incomplete or older than
  /// [maxStaleness]. The same request yields the same handle until released.
  ///
  /// No live subscription for now, so events published afterwards show up on a
  /// later call, once coverage went stale.
  SyncHandle ensure(SyncRequest request) {
    final id = request.id ?? _identityOf(request);
    final existing = _registrations[id];

    if (existing == null) {
      final handle = SyncHandle(id);
      _registrations[id] = _Registration(
        handle: handle,
        request: request,
        subject: BehaviorSubject.seeded(
          SyncRequestStatus(handle: handle, phase: SyncRequestPhase.idle),
        ),
      );
    } else {
      existing.holders++;
    }

    unawaited(_sync(id));
    _publishEngineStatus();

    return _registrations[id]!.handle;
  }

  SyncRequestStatus status(SyncHandle handle) => _subjectFor(handle).value;

  Stream<SyncRequestStatus> watchStatus(SyncHandle handle) =>
      _subjectFor(handle).stream;

  /// Fetches what appeared since the last pass, ignoring [maxStaleness]. This
  /// is the pull to refresh gesture. Waits for a pass already under way before
  /// starting its own, so the caller never observes a half refreshed state.
  Future<void> refresh(SyncHandle handle) async {
    final registration = _registrations[handle.id];
    if (registration == null) throw StateError('Unknown handle: $handle');

    await registration.running;
    await _sync(handle.id, staleness: Duration.zero);
  }

  /// Drops the caller's interest in [handle]. Sync state stays persisted, and
  /// the work already in flight is left to finish.
  void release(SyncHandle handle) {
    final registration = _registrations[handle.id];
    if (registration == null) return;

    registration.holders--;
    if (registration.holders > 0) return;

    _registrations.remove(handle.id);
    unawaited(registration.subject.close());
    _publishEngineStatus();
  }

  SyncEngineStatus get engineStatus => _engineStatus.value;

  Stream<SyncEngineStatus> watchEngineStatus() => _engineStatus.stream;

  Future<void> dispose() async {
    await stop();

    for (final registration in _registrations.values) {
      await registration.subject.close();
    }
    _registrations.clear();
    _queues.clear();

    await _engineStatus.close();
  }

  /// Runs a pass for [id], or joins the one already running.
  Future<void> _sync(String id, {Duration? staleness}) {
    final registration = _registrations[id];
    if (registration == null || !_started) return Future.value();

    final running = registration.running;
    if (running != null) return running;

    final pass = _pass(registration, staleness).whenComplete(() {
      registration.running = null;
      _publishEngineStatus();
    });

    registration.running = pass;
    _publishEngineStatus();

    return pass;
  }

  Future<void> _pass(_Registration registration, Duration? staleness) async {
    final startedAt = DateTime.now().toUtc();
    _emit(registration, SyncRequestPhase.syncing);

    // Waiting on every relay of the request only gates this status update.
    // Each relay keeps draining its own queue meanwhile.
    final answers = await Future.wait([
      for (final relayUrl in registration.request.relays)
        _enqueue(
          relayUrl,
          () => _syncRelay(registration, relayUrl, staleness, startedAt),
        ),
    ]);

    _emit(
      registration,
      // One relay answering is enough: the silent ones are retried later.
      answers.contains(true)
          ? SyncRequestPhase.synced
          : SyncRequestPhase.failed,
      states: await _statesOf(registration.request),
    );
  }

  /// Every filter of [registration] on this one relay, one after the other.
  /// Returns false when the relay left something unanswered.
  Future<bool> _syncRelay(
    _Registration registration,
    String relayUrl,
    Duration? staleness,
    DateTime startedAt,
  ) async {
    final request = registration.request;
    var answered = true;

    for (final filter in request.filters) {
      final tasks = planFilterOnRelay(
        relayUrl: relayUrl,
        filter: filter,
        state: await store.readSyncState(
          relayUrl: relayUrl,
          filterFingerprint: filterFingerprint(filter),
          authPubkey: request.authPubkey,
        ),
        now: startedAt,
        maxStaleness: staleness ?? request.maxStaleness ?? maxStaleness,
        overlapMargin: request.overlapMargin ?? overlapMargin,
      );

      for (final task in tasks) {
        final done = await _runner.run(
          task,
          authPubkey: request.authPubkey,
          startedAt: startedAt,
        );
        if (!done) answered = false;
      }
    }

    return answered;
  }

  /// Queues [work] behind whatever this relay is already doing. Relays are
  /// keyed by normalised url, otherwise two spellings would mean two queues,
  /// and two queries at once on a single relay.
  Future<bool> _enqueue(String relayUrl, Future<bool> Function() work) {
    final queue = _queues.putIfAbsent(
      cleanRelayUrl(relayUrl) ?? relayUrl,
      _RelayQueue.new,
    );
    final job = _Job(work);

    queue.jobs.add(job);
    unawaited(_drain(queue));

    return job.done.future;
  }

  Future<void> _drain(_RelayQueue queue) async {
    if (queue.busy) return;
    queue.busy = true;

    while (queue.jobs.isNotEmpty) {
      final job = queue.jobs.removeFirst();
      try {
        job.done.complete(await job.work());
      } catch (error, stackTrace) {
        job.done.completeError(error, stackTrace);
      }
    }

    queue.busy = false;
  }

  Future<List<RelayFilterSyncState>> _statesOf(SyncRequest request) async {
    final states = <RelayFilterSyncState>[];

    for (final relayUrl in request.relays) {
      for (final filter in request.filters) {
        final state = await store.readSyncState(
          relayUrl: relayUrl,
          filterFingerprint: filterFingerprint(filter),
          authPubkey: request.authPubkey,
        );
        if (state != null) states.add(state);
      }
    }

    return states;
  }

  void _emit(
    _Registration registration,
    SyncRequestPhase phase, {
    List<RelayFilterSyncState> states = const [],
  }) {
    if (registration.subject.isClosed) return;

    registration.subject.add(
      SyncRequestStatus(
        handle: registration.handle,
        phase: phase,
        relayStates: states,
      ),
    );
  }

  void _publishEngineStatus() {
    if (_engineStatus.isClosed) return;

    final registrations = _registrations.values;
    final running = registrations.where((r) => r.running != null).length;

    _engineStatus.add(
      SyncEngineStatus(
        phase: !_started
            ? SyncEnginePhase.stopped
            : running > 0
            ? SyncEnginePhase.working
            : SyncEnginePhase.idle,
        activeRequests: registrations.length,
        pendingRequests: registrations
            .where((r) => r.subject.value.phase != SyncRequestPhase.synced)
            .length,
      ),
    );
  }

  Future<void> _inFlight() => Future.wait([
    for (final registration in _registrations.values)
      if (registration.running != null) registration.running!,
  ]);

  /// Two requests asking the same thing share a handle, whatever the order of
  /// their filters and relays.
  String _identityOf(SyncRequest request) {
    final filters = [
      for (final filter in request.filters) filterFingerprint(filter),
    ]..sort();
    final relays = [
      for (final relay in request.relays) cleanRelayUrl(relay) ?? relay,
    ]..sort();

    return '${filters.join(',')}|${request.authPubkey ?? ''}|'
        '${relays.join(',')}';
  }

  BehaviorSubject<SyncRequestStatus> _subjectFor(SyncHandle handle) {
    final registration = _registrations[handle.id];
    if (registration == null) throw StateError('Unknown handle: $handle');

    return registration.subject;
  }
}

class _Registration {
  _Registration({
    required this.handle,
    required this.request,
    required this.subject,
  });

  final SyncHandle handle;
  final SyncRequest request;
  final BehaviorSubject<SyncRequestStatus> subject;

  /// Callers holding this handle. The registration goes away at zero.
  int holders = 1;

  Future<void>? running;
}

/// Serialises the work aimed at one relay.
class _RelayQueue {
  final jobs = Queue<_Job>();
  var busy = false;
}

class _Job {
  _Job(this.work);

  final Future<bool> Function() work;
  final done = Completer<bool>();
}
