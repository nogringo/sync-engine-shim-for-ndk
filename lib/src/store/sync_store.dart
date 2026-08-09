import 'package:sembast/sembast.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/relay_filter_sync_state.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/relay_knowledge.dart';

/// Persists what has already been synced, so a restart does not refetch it.
class SyncStore {
  SyncStore({required this.db});

  static const syncStateStoreName = 'relay_filter_sync_states';
  static const relayKnowledgeStoreName = 'relay_knowledge';

  final Database db;

  Future<RelayFilterSyncState?> readSyncState({
    required String relayUrl,
    required String filterFingerprint,
    String? authPubkey,
  }) {
    throw UnimplementedError();
  }

  Future<void> writeSyncState(RelayFilterSyncState state) {
    throw UnimplementedError();
  }

  Future<RelayKnowledge?> readRelayKnowledge(String relayUrl) {
    throw UnimplementedError();
  }

  Future<void> writeRelayKnowledge(RelayKnowledge knowledge) {
    throw UnimplementedError();
  }
}
