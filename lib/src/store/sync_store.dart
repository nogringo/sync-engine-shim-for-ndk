import 'package:sync_engine_shim_for_ndk/src/entities/relay_filter_sync_state.dart';

/// Persists what has already been synced, so a restart does not refetch it.
/// Relay urls arrive normalised, dates must read back in UTC, and a null
/// `authPubkey` names the anonymous states only, not all of them.
abstract interface class SyncStore {
  Future<RelayFilterSyncState?> readSyncState({
    required String relayUrl,
    required String filterFingerprint,
    String? authPubkey,
  });

  /// Every state persisted for this filter, whatever the relay.
  Future<List<RelayFilterSyncState>> readSyncStates({
    required String filterFingerprint,
    String? authPubkey,
  });

  Future<void> writeSyncState(RelayFilterSyncState state);

  Future<void> deleteSyncState({
    required String relayUrl,
    required String filterFingerprint,
    String? authPubkey,
  });

  /// Forgets this filter on every relay it was synced from.
  Future<void> deleteSyncStates({
    required String filterFingerprint,
    String? authPubkey,
  });

  /// Drops everything this store persisted. Local only.
  Future<void> clear();
}
