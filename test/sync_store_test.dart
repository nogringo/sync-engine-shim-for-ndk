import 'package:sembast/sembast_memory.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/relay_filter_sync_state.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/relay_knowledge.dart';
import 'package:sync_engine_shim_for_ndk/src/store/sync_store.dart';
import 'package:test/test.dart';

const fingerprint = 'a1b2c3d4e5f60718';
const alice =
    '56e8c688aabb49e9bb68f9d8d6722c809366ad1ad959042db45970cc63152d75';
const relay = 'wss://relay.example.com';

final january = DateTime.utc(2026, 1, 1);
final march = DateTime.utc(2026, 3, 31, 23, 59, 59);
final april = DateTime.utc(2026, 4, 1, 10, 30);

void main() {
  late SyncStore store;

  setUp(() async {
    // A fresh factory per test, otherwise memory databases are shared by name.
    final db = await newDatabaseFactoryMemory().openDatabase('sync_engine.db');
    store = SyncStore(db: db);
  });

  group('sync state', () {
    test('round trips', () async {
      await store.writeSyncState(
        RelayFilterSyncState(
          relayUrl: relay,
          filterFingerprint: fingerprint,
          authPubkey: alice,
          coverage: [
            CoverageRange(from: january, to: march, completedAt: april),
          ],
          lastAttemptAt: april,
        ),
      );

      final read = await store.readSyncState(
        relayUrl: relay,
        filterFingerprint: fingerprint,
        authPubkey: alice,
      );

      expect(read!.relayUrl, relay);
      expect(read.filterFingerprint, fingerprint);
      expect(read.authPubkey, alice);
      expect(read.lastAttemptAt, april);
      expect(read.coverage, [
        CoverageRange(from: january, to: march, completedAt: april),
      ]);
    });

    test('round trips a state without auth nor attempt', () async {
      await store.writeSyncState(
        RelayFilterSyncState(relayUrl: relay, filterFingerprint: fingerprint),
      );

      final read = await store.readSyncState(
        relayUrl: relay,
        filterFingerprint: fingerprint,
      );

      expect(read!.authPubkey, isNull);
      expect(read.lastAttemptAt, isNull);
      expect(read.coverage, isEmpty);
    });

    test('returns null when nothing was written', () async {
      final read = await store.readSyncState(
        relayUrl: relay,
        filterFingerprint: fingerprint,
      );

      expect(read, isNull);
    });

    test('reads back through another spelling of the relay url', () async {
      await store.writeSyncState(
        RelayFilterSyncState(relayUrl: relay, filterFingerprint: fingerprint),
      );

      final read = await store.readSyncState(
        relayUrl: 'wss://Relay.Example.com:443/',
        filterFingerprint: fingerprint,
      );

      expect(read, isNotNull);
    });

    test('keeps authenticated and anonymous states apart', () async {
      await store.writeSyncState(
        RelayFilterSyncState(
          relayUrl: relay,
          filterFingerprint: fingerprint,
          authPubkey: alice,
          lastAttemptAt: april,
        ),
      );

      final anonymous = await store.readSyncState(
        relayUrl: relay,
        filterFingerprint: fingerprint,
      );

      expect(anonymous, isNull);
    });

    test('keeps filters apart', () async {
      await store.writeSyncState(
        RelayFilterSyncState(relayUrl: relay, filterFingerprint: fingerprint),
      );

      final other = await store.readSyncState(
        relayUrl: relay,
        filterFingerprint: '0000000000000000',
      );

      expect(other, isNull);
    });

    test('overwrites the previous state of the same key', () async {
      await store.writeSyncState(
        RelayFilterSyncState(relayUrl: relay, filterFingerprint: fingerprint),
      );
      await store.writeSyncState(
        RelayFilterSyncState(
          relayUrl: relay,
          filterFingerprint: fingerprint,
          coverage: [
            CoverageRange(from: january, to: march, completedAt: april),
          ],
        ),
      );

      final read = await store.readSyncState(
        relayUrl: relay,
        filterFingerprint: fingerprint,
      );

      expect(read!.coverage, hasLength(1));
    });
  });

  group('relay knowledge', () {
    test('round trips', () async {
      await store.writeRelayKnowledge(
        RelayKnowledge(
          relayUrl: relay,
          lastConnectedAt: april,
          lastFailureAt: january,
        ),
      );

      final read = await store.readRelayKnowledge(relay);

      expect(read!.relayUrl, relay);
      expect(read.lastConnectedAt, april);
      expect(read.lastFailureAt, january);
    });

    test('reads back through another spelling of the relay url', () async {
      await store.writeRelayKnowledge(
        RelayKnowledge(relayUrl: '$relay/', lastConnectedAt: april),
      );

      final read = await store.readRelayKnowledge(relay);

      expect(read!.lastFailureAt, isNull);
      expect(read.lastConnectedAt, april);
    });

    test('returns null when nothing was written', () async {
      expect(await store.readRelayKnowledge(relay), isNull);
    });
  });
}
