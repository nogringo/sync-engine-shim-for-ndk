import 'package:ndk/ndk.dart';
import 'package:ndk/shared/nips/nip01/bip340.dart';
import 'package:sembast/sembast_memory.dart' hide Filter;
import 'package:sync_engine_shim_for_ndk/src/filter_fingerprint.dart';
import 'package:sync_engine_shim_for_ndk/src/planner.dart';
import 'package:sync_engine_shim_for_ndk/src/store/sync_store.dart';
import 'package:sync_engine_shim_for_ndk/src/task_runner.dart';
import 'package:test/test.dart';

import 'mocks/mock_relay.dart';

final startedAt = DateTime.utc(2026, 8, 9, 12);
final author = Bip340.generatePrivateKey();

final signer = Bip340EventSigner(
  privateKey: author.privateKey,
  publicKey: author.publicKey,
);

int at(int secondsAgo) => startedAt.millisecondsSinceEpoch ~/ 1000 - secondsAgo;

int secondsOf(DateTime date) => date.millisecondsSinceEpoch ~/ 1000;

SyncTask taskFor(String relayUrl, {required int since, required int until}) =>
    SyncTask(
      relayUrl: relayUrl,
      filter: Filter(kinds: [1], authors: [author.publicKey])
        ..since = since
        ..until = until,
    );

void main() {
  late MockRelay relay;
  late MemCacheManager cache;
  late Ndk ndk;
  late SyncStore store;
  late TaskRunner runner;

  setUp(() async {
    relay = MockRelay(name: 'runner');
    await relay.startServer();

    cache = MemCacheManager();
    ndk = Ndk(
      NdkConfig(
        eventVerifier: Bip340EventVerifier(),
        cache: cache,
        bootstrapRelays: [relay.url],
      ),
    );

    final db = await newDatabaseFactoryMemory().openDatabase('sync_engine.db');
    store = SyncStore(db: db);
    runner = TaskRunner(ndk: ndk, store: store, pageLimit: 2);
  });

  tearDown(() async {
    await relay.stopServer();
  });

  Future<void> publish(List<int> createdAts) async {
    for (final createdAt in createdAts) {
      await ndk.broadcast
          .broadcast(
            nostrEvent: Nip01Event(
              pubKey: author.publicKey,
              kind: 1,
              tags: const [],
              content: 'note at $createdAt',
              createdAt: createdAt,
            ),
            specificRelays: [relay.url],
            customSigner: signer,
            // Otherwise the cache is filled by the publish, not by the runner.
            saveToCache: false,
          )
          .broadcastDoneFuture;
    }
  }

  Future<List<({int from, int to})>> coverageOf(
    Filter filter, {
    String? relayUrl,
  }) async {
    final state = await store.readSyncState(
      relayUrl: relayUrl ?? relay.url,
      filterFingerprint: filterFingerprint(filter),
    );

    return [
      for (final range in state?.coverage ?? const [])
        (from: secondsOf(range.from), to: secondsOf(range.to)),
    ];
  }

  test('covers the whole window when the relay has nothing', () async {
    final task = taskFor(relay.url, since: at(3600), until: at(0));

    expect(await runner.run(task, startedAt: startedAt), isTrue);
    expect(await coverageOf(task.filter), [(from: at(3600), to: at(0))]);
  });

  test('walks a window that needs several pages', () async {
    await publish([at(50), at(40), at(30), at(20), at(10)]);
    final task = taskFor(relay.url, since: at(3600), until: at(0));

    expect(await runner.run(task, startedAt: startedAt), isTrue);
    expect(await coverageOf(task.filter), [(from: at(3600), to: at(0))]);
  });

  test('fills the NDK cache along the way', () async {
    await publish([at(50), at(40), at(30)]);
    final task = taskFor(relay.url, since: at(3600), until: at(0));

    await runner.run(task, startedAt: startedAt);

    final cached = await cache.loadEvents(
      kinds: [1],
      pubKeys: [author.publicKey],
    );

    expect(cached, hasLength(3));
  });

  test('stops at the window it was given', () async {
    await publish([at(50), at(40), at(30)]);
    final task = taskFor(relay.url, since: at(45), until: at(35));

    await runner.run(task, startedAt: startedAt);

    expect(await coverageOf(task.filter), [(from: at(45), to: at(35))]);

    final cached = await cache.loadEvents(
      kinds: [1],
      pubKeys: [author.publicKey],
    );
    expect(cached, hasLength(1));
  });

  test('records nothing when the relay is unreachable', () async {
    await relay.stopServer();
    final task = taskFor(relay.url, since: at(3600), until: at(0));

    expect(
      await runner.run(task, startedAt: startedAt),
      isFalse,
      reason: 'an unreachable relay must not look like an exhausted one',
    );
    expect(await coverageOf(task.filter), isEmpty);
  });

  test('records nothing when a reachable relay stays silent', () async {
    final silent = MockRelay(name: 'silent');
    await silent.startServer(delayResponse: const Duration(seconds: 2));
    addTearDown(silent.stopServer);

    final impatient = TaskRunner(
      ndk: ndk,
      store: store,
      timeout: const Duration(milliseconds: 300),
    );
    final task = taskFor(silent.url, since: at(3600), until: at(0));

    expect(
      await impatient.run(task, startedAt: startedAt),
      isFalse,
      reason: 'the relay is connected, only the answer never came',
    );
    expect(await coverageOf(task.filter, relayUrl: silent.url), isEmpty);
  });

  test('remembers the attempt even when it failed', () async {
    await relay.stopServer();
    final task = taskFor(relay.url, since: at(3600), until: at(0));

    await runner.run(task, startedAt: startedAt);
    final state = await store.readSyncState(
      relayUrl: relay.url,
      filterFingerprint: filterFingerprint(task.filter),
    );

    expect(state!.lastAttemptAt, startedAt);
  });

  test('merges a second run into the coverage of the first', () async {
    await publish([at(50), at(40)]);
    final first = taskFor(relay.url, since: at(60), until: at(30));
    final second = taskFor(relay.url, since: at(29), until: at(0));

    await runner.run(first, startedAt: startedAt);
    await runner.run(second, startedAt: startedAt);

    expect(await coverageOf(first.filter), [(from: at(60), to: at(0))]);
  });
}
