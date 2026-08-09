import 'package:ndk/shared/helpers/relay_helper.dart';
import 'package:sembast/sembast.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/relay_filter_sync_state.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/relay_knowledge.dart';

/// Persists what has already been synced, so a restart does not refetch it.
/// Timestamps are stored as epoch milliseconds and read back in UTC.
class SyncStore {
  SyncStore({required this.db});

  static const syncStateStoreName = 'relay_filter_sync_states';
  static const relayKnowledgeStoreName = 'relay_knowledge';

  final Database db;

  final _syncStates = stringMapStoreFactory.store(syncStateStoreName);
  final _relayKnowledge = stringMapStoreFactory.store(relayKnowledgeStoreName);

  Future<RelayFilterSyncState?> readSyncState({
    required String relayUrl,
    required String filterFingerprint,
    String? authPubkey,
  }) async {
    final record = await _syncStates
        .record(
          _syncStateKey(
            relayUrl: relayUrl,
            filterFingerprint: filterFingerprint,
            authPubkey: authPubkey,
          ),
        )
        .get(db);

    return record == null ? null : _syncStateFrom(record);
  }

  Future<void> writeSyncState(RelayFilterSyncState state) async {
    await _syncStates
        .record(
          _syncStateKey(
            relayUrl: state.relayUrl,
            filterFingerprint: state.filterFingerprint,
            authPubkey: state.authPubkey,
          ),
        )
        .put(db, _syncStateTo(state));
  }

  Future<RelayKnowledge?> readRelayKnowledge(String relayUrl) async {
    final record = await _relayKnowledge.record(_relayKey(relayUrl)).get(db);

    return record == null ? null : _relayKnowledgeFrom(record);
  }

  Future<void> writeRelayKnowledge(RelayKnowledge knowledge) async {
    await _relayKnowledge
        .record(_relayKey(knowledge.relayUrl))
        .put(db, _relayKnowledgeTo(knowledge));
  }

  /// Fixed width fields first, and `|` as separator: a relay url carries its
  /// own colons, in `wss://` and in a non default port.
  String _syncStateKey({
    required String relayUrl,
    required String filterFingerprint,
    String? authPubkey,
  }) => '$filterFingerprint|${authPubkey ?? ''}|${_relayKey(relayUrl)}';

  String _relayKey(String relayUrl) => cleanRelayUrl(relayUrl) ?? relayUrl;

  Map<String, Object?> _syncStateTo(RelayFilterSyncState state) => {
    'relayUrl': state.relayUrl,
    'filterFingerprint': state.filterFingerprint,
    'authPubkey': state.authPubkey,
    'coverage': [
      for (final range in state.coverage)
        {
          'from': range.from.millisecondsSinceEpoch,
          'to': range.to.millisecondsSinceEpoch,
          'completedAt': range.completedAt.millisecondsSinceEpoch,
        },
    ],
    'lastAttemptAt': state.lastAttemptAt?.millisecondsSinceEpoch,
  };

  RelayFilterSyncState _syncStateFrom(Map<String, Object?> record) =>
      RelayFilterSyncState(
        relayUrl: record['relayUrl'] as String,
        filterFingerprint: record['filterFingerprint'] as String,
        authPubkey: record['authPubkey'] as String?,
        coverage: [
          for (final range in record['coverage'] as List? ?? const [])
            _rangeFrom((range as Map).cast<String, Object?>()),
        ],
        lastAttemptAt: _dateFrom(record['lastAttemptAt']),
      );

  CoverageRange _rangeFrom(Map<String, Object?> record) => CoverageRange(
    from: _dateFrom(record['from'])!,
    to: _dateFrom(record['to'])!,
    completedAt: _dateFrom(record['completedAt'])!,
  );

  Map<String, Object?> _relayKnowledgeTo(RelayKnowledge knowledge) => {
    'relayUrl': knowledge.relayUrl,
    'lastConnectedAt': knowledge.lastConnectedAt?.millisecondsSinceEpoch,
    'lastFailureAt': knowledge.lastFailureAt?.millisecondsSinceEpoch,
  };

  RelayKnowledge _relayKnowledgeFrom(Map<String, Object?> record) =>
      RelayKnowledge(
        relayUrl: record['relayUrl'] as String,
        lastConnectedAt: _dateFrom(record['lastConnectedAt']),
        lastFailureAt: _dateFrom(record['lastFailureAt']),
      );

  DateTime? _dateFrom(Object? value) => value == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(value as int, isUtc: true);
}
