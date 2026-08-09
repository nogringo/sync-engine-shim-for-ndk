import 'package:ndk/ndk.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sembast/sembast.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/sync_engine_status.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/sync_handle.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/sync_request.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/sync_request_status.dart';
import 'package:sync_engine_shim_for_ndk/src/store/sync_store.dart';

/// Downward sync only: the engine fills the NDK cache, it never broadcasts.
/// Callers read events from the NDK cache, not from this API.
class SyncEngine {
  SyncEngine(
    this.ndk, {
    required Database db,
    this.maxStaleness = const Duration(minutes: 5),
    this.overlapMargin = const Duration(days: 1),
  }) : store = SyncStore(db: db);

  final Ndk ndk;
  final SyncStore store;

  /// How old coverage may get before [ensure] goes back to the relays.
  final Duration maxStaleness;

  /// How far back a new pass reaches beyond existing coverage, to absorb clock
  /// skew and late deliveries.
  final Duration overlapMargin;

  final _engineStatus = BehaviorSubject<SyncEngineStatus>.seeded(
    const SyncEngineStatus(phase: SyncEnginePhase.stopped),
  );
  final _requestStatuses = <SyncHandle, BehaviorSubject<SyncRequestStatus>>{};

  /// Starts processing registered requests.
  void start() {
    throw UnimplementedError();
  }

  /// Stops all sync work. Handles and persisted state survive.
  Future<void> stop() {
    throw UnimplementedError();
  }

  /// Keeps [request] available in the cache: the engine fills whatever is
  /// missing, down to each filter's `since`. Cheap to call repeatedly, it only
  /// goes to the relays when coverage is incomplete or older than
  /// [maxStaleness]. The same request yields the same handle until released.
  ///
  /// No live subscription for now, so events published afterwards show up on a
  /// later call, once coverage went stale.
  SyncHandle ensure(SyncRequest request) {
    throw UnimplementedError();
  }

  SyncRequestStatus status(SyncHandle handle) => _subjectFor(handle).value;

  Stream<SyncRequestStatus> watchStatus(SyncHandle handle) =>
      _subjectFor(handle).stream;

  /// Fetches what appeared since the last pass, ignoring [maxStaleness]. This
  /// is the pull to refresh gesture.
  Future<void> refresh(SyncHandle handle) {
    throw UnimplementedError();
  }

  /// Drops the caller's interest in [handle]. Sync state stays persisted.
  void release(SyncHandle handle) {
    throw UnimplementedError();
  }

  SyncEngineStatus get engineStatus => _engineStatus.value;

  Stream<SyncEngineStatus> watchEngineStatus() => _engineStatus.stream;

  Future<void> dispose() {
    throw UnimplementedError();
  }

  BehaviorSubject<SyncRequestStatus> _subjectFor(SyncHandle handle) {
    final subject = _requestStatuses[handle];
    if (subject == null) {
      throw StateError('Unknown handle: $handle');
    }
    return subject;
  }
}
