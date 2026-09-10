import 'dart:async';
import 'dart:collection';

import 'package:ndk/ndk.dart';
import 'package:ndk/shared/helpers/relay_helper.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sembast/sembast.dart' hide Filter;
import 'package:sync_engine_shim_for_ndk/src/entities/relay_filter_sync_state.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/sync_auth_error.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/sync_engine_status.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/sync_handle.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/sync_progress.dart';
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
    this.minRevisitPeriod = const Duration(seconds: 15),
    this.overlapMargin = const Duration(days: 1),
    this.initialBackoff = const Duration(seconds: 5),
    this.maxBackoff = const Duration(minutes: 5),
  }) : store = SyncStore(db: db) {
    _runner = TaskRunner(ndk: ndk, store: store);
  }

  final Ndk ndk;
  final SyncStore store;

  /// How old coverage may get before the engine goes back to the relays. It is
  /// both what [ensure] checks and how often a registered request revisits its
  /// windows on its own, down to [minRevisitPeriod].
  final Duration maxStaleness;

  /// Floor under the revisiting, whatever [maxStaleness] asks for. Polling
  /// faster than this is not polling any more, it is a subscription written
  /// the wrong way round, and the engine does not know how to subscribe yet.
  /// The floor goes the day it does.
  final Duration minRevisitPeriod;

  /// How far back a new pass reaches beyond existing coverage, to absorb clock
  /// skew and late deliveries.
  final Duration overlapMargin;

  /// Wait before going back to a relay that left something unanswered. It
  /// doubles on every consecutive failure, up to [maxBackoff], and resets as
  /// soon as that relay answers. Backoff is per relay: a dead relay slows down
  /// on its own without holding back the others.
  final Duration initialBackoff;

  final Duration maxBackoff;

  late final TaskRunner _runner;

  final _engineStatus = BehaviorSubject<SyncEngineStatus>.seeded(
    const SyncEngineStatus(phase: SyncEnginePhase.stopped),
  );
  final _registrations = <String, _Registration>{};
  final _queues = <String, _RelayQueue>{};

  /// Every pass still walking, released ones included. A registration leaves
  /// [_registrations] as soon as its last holder does, while its pass still
  /// owns a relay query and a store write, so tracking them here is what lets
  /// [stop] wait for work nobody is registered for any more.
  final _passes = <Future<void>>{};

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

  /// Stops the work, at the next page of whatever is walking. Handles and
  /// persisted state survive, and [start] picks up where this left off. This
  /// is what an app backgrounding itself calls: no request keeps ticking.
  Future<void> stop() async {
    _started = false;

    // Nothing can arm a new one now that the engine is stopped.
    for (final registration in _registrations.values) {
      registration.tick?.cancel();
      registration.tick = null;
    }

    await _inFlight();

    // After the walks, not before: a job landing on an unreachable relay arms
    // its own retry, and one armed mid-stop would outlive this call.
    for (final queue in _queues.values) {
      queue.retry?.cancel();
      queue.retry = null;
    }

    _publishEngineStatus();
  }

  /// Keeps [request] available in the cache, and keeps it up to date: the
  /// engine fills whatever is missing, down to each filter's `since`, then
  /// revisits the recent end every [maxStaleness] for as long as the handle is
  /// held. Cheap to call repeatedly, it only goes to the relays when coverage
  /// is incomplete or stale. The same request yields the same handle until
  /// released.
  ///
  /// No live subscription for now, so an event published afterwards lands
  /// within [maxStaleness] rather than the moment it is signed. [refresh] is
  /// there for when that wait is too long.
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

  /// What is already synced for [request], one entry per relay and filter pair
  /// that has coverage. Reads the local state, it never goes to the relays, and
  /// the request does not have to be registered.
  Future<List<RelayFilterSyncState>> coverageOf(SyncRequest request) async {
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

  /// What is already synced for [filter], on every relay it was synced from
  /// rather than on the relays a request happens to name.
  Future<List<RelayFilterSyncState>> coverageOfFilter(
    Filter filter, {
    String? authPubkey,
  }) => store.readSyncStates(
    filterFingerprint: filterFingerprint(filter),
    authPubkey: authPubkey,
  );

  /// Fetches what appeared since the last pass, ignoring [maxStaleness]. This
  /// is the pull to refresh gesture. Waits for a pass already under way before
  /// starting its own, so the caller never observes a half refreshed state.
  Future<void> refresh(SyncHandle handle) async {
    final registration = _registrations[handle.id];
    if (registration == null) throw StateError('Unknown handle: $handle');

    await registration.running;
    await _sync(handle.id, staleness: Duration.zero);
  }

  /// Drops the caller's interest in [handle]. What was synced stays
  /// persisted, and a walk still running stops at its next page rather than
  /// spending network on a request nobody wants any more.
  void release(SyncHandle handle) {
    final registration = _registrations[handle.id];
    if (registration == null) return;

    registration.holders--;
    if (registration.holders > 0) return;

    registration.cancelled = true;
    registration.tick?.cancel();
    _registrations.remove(handle.id);
    unawaited(registration.subject.close());
    _publishEngineStatus();
  }

  /// Forgets what was synced for [request], so its next pass walks it back
  /// from scratch. Coverage is per filter and relay, not per window: every
  /// window of these filters on these relays goes. Local only.
  Future<void> forget(SyncRequest request) {
    final registration = _registrations[request.id ?? _identityOf(request)];

    return _forgetting([?registration], () => _deleteStatesOf(request));
  }

  /// Forgets what was synced for [filter], on every relay it was synced from
  /// rather than on the relays a request happens to name. Every held request
  /// carrying that filter under [authPubkey] walks it back from scratch. Local
  /// only.
  Future<void> forgetFilter(Filter filter, {String? authPubkey}) {
    final fingerprint = filterFingerprint(filter);

    return _forgetting(
      [
        for (final registration in _registrations.values)
          if (registration.request.authPubkey == authPubkey &&
              registration.request.filters.any(
                (held) => filterFingerprint(held) == fingerprint,
              ))
            registration,
      ],
      () => store.deleteSyncStates(
        filterFingerprint: fingerprint,
        authPubkey: authPubkey,
      ),
    );
  }

  /// Wipes persisted state under the requests that hold it: their pass lands
  /// first, and they start over on what they still want once it is gone.
  Future<void> _forgetting(
    List<_Registration> held,
    Future<void> Function() wipe,
  ) async {
    await Future.wait([for (final registration in held) ?registration.running]);

    // The passes that just landed re-armed their tick.
    for (final registration in held) {
      registration.tick?.cancel();
      registration.tick = null;
    }

    // A pass asked meanwhile joins the wipe instead of walking a state half gone.
    final wiping = wipe();
    for (final registration in held) {
      registration.running = wiping;
    }
    try {
      await wiping;
    } finally {
      for (final registration in held) {
        registration.running = null;
      }
    }

    for (final registration in held) {
      unawaited(_sync(registration.handle.id));
    }
  }

  Future<void> _deleteStatesOf(SyncRequest request) async {
    for (final relayUrl in request.relays) {
      for (final filter in request.filters) {
        await store.deleteSyncState(
          relayUrl: relayUrl,
          filterFingerprint: filterFingerprint(filter),
          authPubkey: request.authPubkey,
        );
      }
    }
  }

  /// Forgets everything this package persisted, for a full app reset. Local
  /// only. Walks in flight land first, and held requests start over.
  Future<void> clearAllLocalData() async {
    final wasStarted = _started;

    await stop();
    await store.clear();
    if (wasStarted) start();
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

    // Signalled from the callback the pass already had, rather than from a
    // listener of its own: a second listener would carry the error into a
    // future nobody reads, and report it a second time behind the back of the
    // caller who handled it.
    final landed = Completer<void>();
    _passes.add(landed.future);

    final pass = _pass(registration, staleness).whenComplete(() {
      registration.running = null;
      _passes.remove(landed.future);
      landed.complete();
      _scheduleTick(id);
      _publishEngineStatus();
    });

    registration.running = pass;
    _publishEngineStatus();

    return pass;
  }

  /// Arms the pass that will follow the one that just ran, so that a held
  /// request keeps up with the relays without the app asking again.
  ///
  /// A request whose windows have all closed and whose last pass found nothing
  /// left to fetch is done for good: it stops ticking instead of polling an
  /// archive until the app quits. An open window always ticks on, since the
  /// world keeps publishing into it.
  void _scheduleTick(String id) {
    final registration = _registrations[id];
    if (registration == null || !_started) return;

    registration.tick?.cancel();
    registration.tick = null;

    final request = registration.request;
    final now = DateTime.now().toUtc();
    final open = request.filters.any((filter) => _isOpen(filter, now));
    if (!open && !registration.planned) return;

    final asked = request.maxStaleness ?? maxStaleness;
    final period = asked < minRevisitPeriod ? minRevisitPeriod : asked;

    registration.tick = Timer(period, () {
      registration.tick = null;
      unawaited(_sync(id));
    });
  }

  /// Whether [filter] still reaches into the future, and so may gain events
  /// the engine has never seen. A window closed before [now] cannot.
  bool _isOpen(Filter filter, DateTime now) {
    final until = filter.until;
    if (until == null) return true;

    return DateTime.fromMillisecondsSinceEpoch(
      until * 1000,
      isUtc: true,
    ).isAfter(now);
  }

  Future<void> _pass(_Registration registration, Duration? staleness) async {
    final startedAt = DateTime.now().toUtc();
    registration.planned = false;
    registration.lastError = null;
    _emit(registration, phase: SyncRequestPhase.syncing);

    final RelayAuth auth;
    try {
      auth = _authFor(registration.request);
    } on SyncAuthUnavailable catch (error) {
      registration.lastError = error;
      // Nothing was read, so everything is still to do: keep ticking, the
      // account may show up between two passes.
      registration.planned = true;
      _emit(registration, phase: SyncRequestPhase.failed);
      return;
    }

    // Waiting on every relay of the request only gates this status update.
    // Each relay keeps draining its own queue meanwhile.
    final outcomes = await Future.wait([
      for (final relayUrl in registration.request.relays)
        _enqueue(
          relayUrl,
          () => _syncRelay(registration, relayUrl, staleness, startedAt, auth),
        ),
    ]);

    if (outcomes.contains(TaskOutcome.cancelled)) {
      // Back to where the request was before this pass: nothing running, and
      // whatever it managed to cover is already persisted.
      _emit(registration, phase: SyncRequestPhase.idle);
      return;
    }

    _emit(
      registration,
      // One relay answering is enough: the silent ones are retried later.
      phase: outcomes.contains(TaskOutcome.answered)
          ? SyncRequestPhase.synced
          : SyncRequestPhase.failed,
      states: await coverageOf(registration.request),
    );
  }

  /// The identity a request goes out under, resolved at query time rather than
  /// at registration: a request declared before its account exists starts
  /// authenticating on its own as soon as the account shows up.
  ///
  /// A request naming nobody gets [RelayAuth.never]. Saying nothing to ndk is
  /// not the same: it would authenticate as the logged account on a refusal,
  /// and the anonymous state would fill with data served under an identity.
  RelayAuth _authFor(SyncRequest request) {
    final pubkey = request.authPubkey;
    if (pubkey == null) return const RelayAuth.never();

    final account = ndk.accounts.accounts[pubkey];
    if (account == null) {
      throw SyncAuthUnavailable(
        pubkey: pubkey,
        reason: SyncAuthFailure.unknownAccount,
      );
    }

    // Left to ndk this would reach no relay at all, and a task reaching no
    // relay reads as unreachable: a misconfiguration would land in the backoff
    // of a relay that did nothing wrong.
    if (!account.signer.canSign()) {
      throw SyncAuthUnavailable(
        pubkey: pubkey,
        reason: SyncAuthFailure.cannotSign,
      );
    }

    return RelayAuth.require(account);
  }

  /// Every filter of [registration] on this one relay, one after the other.
  Future<TaskOutcome> _syncRelay(
    _Registration registration,
    String relayUrl,
    Duration? staleness,
    DateTime startedAt,
    RelayAuth auth,
  ) async {
    final request = registration.request;
    var outcome = TaskOutcome.answered;

    bool cancelled() => registration.cancelled || !_started;

    for (final filter in request.filters) {
      if (cancelled()) return TaskOutcome.cancelled;

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

      if (tasks.isNotEmpty) registration.planned = true;

      for (final task in tasks) {
        final result = await _runner.run(
          task,
          auth: auth,
          startedAt: startedAt,
          isCancelled: cancelled,
          onProgress: (progress) => _emit(registration, progress: progress),
        );

        // Worst wins, and unreachable outranks refused: it is the one that has
        // to reach the backoff.
        if (result == TaskOutcome.cancelled) return TaskOutcome.cancelled;
        if (result == TaskOutcome.unreachable) outcome = result;
        if (result == TaskOutcome.refused && outcome == TaskOutcome.answered) {
          outcome = result;
        }
      }
    }

    return outcome;
  }

  /// Queues [work] behind whatever this relay is already doing. Relays are
  /// keyed by normalised url, otherwise two spellings would mean two queues,
  /// and two queries at once on a single relay.
  Future<TaskOutcome> _enqueue(
    String relayUrl,
    Future<TaskOutcome> Function() work,
  ) {
    final key = cleanRelayUrl(relayUrl) ?? relayUrl;
    final queue = _queues.putIfAbsent(key, () => _RelayQueue(key));
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
        final outcome = await job.work();
        _noteAttempt(queue, outcome);
        job.done.complete(outcome);
      } catch (error, stackTrace) {
        _noteAttempt(queue, TaskOutcome.unreachable);
        job.done.completeError(error, stackTrace);
      }
    }

    queue.busy = false;
  }

  /// A relay that answers clears its own backoff. One that does not gets a
  /// wake up call, which re-runs every request wanting it. Giving up on
  /// purpose leaves the relay's standing untouched.
  ///
  /// So does a refusal, in both directions. Backoff is per relay, not per
  /// filter, so counting a CLOSED would throttle the windows that same relay
  /// serves, and retrying would only be refused again until the request
  /// changes. Clearing it is no better: the pending timer is what the requests
  /// waiting on a real disconnection are going to be woken by.
  void _noteAttempt(_RelayQueue queue, TaskOutcome outcome) {
    if (outcome == TaskOutcome.cancelled || outcome == TaskOutcome.refused) {
      return;
    }

    if (outcome == TaskOutcome.answered) {
      queue.failures = 0;
      queue.retry?.cancel();
      queue.retry = null;
      return;
    }

    queue.failures++;
    if (queue.retry != null) return;

    queue.retry = Timer(_backoffFor(queue.failures), () {
      queue.retry = null;
      for (final registration in _registrations.values) {
        if (_relayKeysOf(registration.request).contains(queue.key)) {
          unawaited(_sync(registration.handle.id));
        }
      }
    });
  }

  Duration _backoffFor(int failures) {
    var backoff = initialBackoff;
    for (var i = 1; i < failures && backoff < maxBackoff; i++) {
      backoff *= 2;
    }

    return backoff > maxBackoff ? maxBackoff : backoff;
  }

  void _emit(
    _Registration registration, {
    SyncRequestPhase? phase,
    List<RelayFilterSyncState>? states,
    SyncProgress? progress,
  }) {
    if (registration.subject.isClosed) return;

    registration.phase = phase ?? registration.phase;
    registration.states = states ?? registration.states;
    registration.progress = progress ?? registration.progress;

    registration.subject.add(
      SyncRequestStatus(
        handle: registration.handle,
        phase: registration.phase,
        relayStates: registration.states,
        lastError: registration.lastError,
        progress: registration.progress,
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

  Future<void> _inFlight() => Future.wait(_passes.toList());

  /// Two requests asking the same thing share a handle, whatever the order of
  /// their filters and relays. The window is part of that: a fingerprint leaves
  /// `since` and `until` out so that pagination does not change what a filter
  /// is, but two periods are two different things to ask for.
  String _identityOf(SyncRequest request) {
    final filters = [
      for (final filter in request.filters) _filterIdentity(filter),
    ]..sort();
    final relays = _relayKeysOf(request).toList()..sort();

    return '${filters.join(',')}|${request.authPubkey ?? ''}|'
        '${relays.join(',')}';
  }

  String _filterIdentity(Filter filter) =>
      '${filterFingerprint(filter)}:${filter.since ?? ''}:'
      '${filter.until ?? ''}';

  Set<String> _relayKeysOf(SyncRequest request) => {
    for (final relay in request.relays) cleanRelayUrl(relay) ?? relay,
  };

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

  /// Set when the last holder let go, read between pages so a long backfill
  /// does not outlive the interest in it.
  var cancelled = false;

  Future<void>? running;

  /// Whether the last pass had anything to fetch. Read once it lands, to tell
  /// a request that still has work to do from one that is over.
  var planned = false;

  /// Armed between two automatic passes, never while one runs.
  Timer? tick;

  /// What the next status will be built from, so that reporting a page does
  /// not have to restate the phase, nor the other way round.
  var phase = SyncRequestPhase.idle;
  List<RelayFilterSyncState> states = const [];
  SyncProgress? progress;

  /// Cleared when a pass starts, so a recovered request stops reporting it.
  Object? lastError;
}

/// Serialises the work aimed at one relay, and carries that relay's backoff.
/// In memory only: a fresh start is an intention to try again now.
class _RelayQueue {
  _RelayQueue(this.key);

  /// Normalised url of the relay.
  final String key;

  final jobs = Queue<_Job>();
  var busy = false;

  /// Consecutive failures on this relay, back to zero as soon as it answers.
  var failures = 0;

  Timer? retry;
}

class _Job {
  _Job(this.work);

  final Future<TaskOutcome> Function() work;
  final done = Completer<TaskOutcome>();
}
