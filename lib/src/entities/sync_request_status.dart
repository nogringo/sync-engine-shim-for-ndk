import 'package:sync_engine_shim_for_ndk/src/entities/relay_filter_sync_state.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/sync_handle.dart';

enum SyncRequestPhase {
  /// Registered, no work started yet.
  idle,

  /// Catching up: recent events, then backfill.
  syncing,

  /// Every relay reached its coverage target, nothing left to do.
  synced,

  /// Every relay failed. The engine keeps retrying.
  failed,
}

class SyncRequestStatus {
  const SyncRequestStatus({
    required this.handle,
    required this.phase,
    this.relayStates = const [],
    this.lastError,
  });

  final SyncHandle handle;
  final SyncRequestPhase phase;

  /// One entry per (relay, filter) pair covered by the request.
  final List<RelayFilterSyncState> relayStates;

  final Object? lastError;
}
