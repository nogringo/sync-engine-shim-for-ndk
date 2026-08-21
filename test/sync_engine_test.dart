import 'package:ndk/ndk.dart';
import 'package:ndk/shared/nips/nip01/bip340.dart';
import 'package:sembast/sembast_memory.dart' hide Filter;
import 'package:sync_engine_shim_for_ndk/sync_engine_shim_for_ndk.dart';
import 'package:test/test.dart';

import 'mocks/mock_relay.dart';

final author = Bip340.generatePrivateKey();
final signer = Bip340EventSigner(
  privateKey: author.privateKey,
  publicKey: author.publicKey,
);

Filter notes() => Filter(kinds: [1], authors: [author.publicKey]);

void main() {
  late MockRelay relay;
  late MemCacheManager cache;
  late Ndk ndk;
  late Database db;
  late SyncEngine engine;

  setUp(() async {
    relay = MockRelay(name: 'engine');
    await relay.startServer();

    cache = MemCacheManager();
    ndk = Ndk(
      NdkConfig(
        eventVerifier: Bip340EventVerifier(),
        cache: cache,
        bootstrapRelays: [relay.url],
      ),
    );

    db = await newDatabaseFactoryMemory().openDatabase('sync_engine.db');
    engine = SyncEngine(
      ndk,
      db: db,
      initialBackoff: const Duration(milliseconds: 200),
      maxBackoff: const Duration(seconds: 1),
    );
  });

  tearDown(() async {
    await engine.dispose();
    await relay.stopServer();
  });

  Future<void> publish(MockRelay target, String content) async {
    await ndk.broadcast
        .broadcast(
          nostrEvent: Nip01Event(
            pubKey: author.publicKey,
            kind: 1,
            tags: const [],
            content: content,
            createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          ),
          specificRelays: [target.url],
          customSigner: signer,
          saveToCache: false,
        )
        .broadcastDoneFuture;
  }

  Future<SyncRequestStatus> settled(SyncHandle handle) => engine
      .watchStatus(handle)
      .firstWhere(
        (status) =>
            status.phase == SyncRequestPhase.synced ||
            status.phase == SyncRequestPhase.failed,
      );

  test('fills the cache for an ensured request', () async {
    await publish(relay, 'hello');
    engine.start();

    final handle = engine.ensure(
      SyncRequest(filters: [notes()], relays: [relay.url]),
    );
    final status = await settled(handle);

    expect(status.phase, SyncRequestPhase.synced);
    expect(await cache.loadEvents(kinds: [1]), hasLength(1));
  });

  test('stays idle until started', () async {
    await publish(relay, 'hello');

    final handle = engine.ensure(
      SyncRequest(filters: [notes()], relays: [relay.url]),
    );

    expect(engine.status(handle).phase, SyncRequestPhase.idle);
    expect(engine.engineStatus.phase, SyncEnginePhase.stopped);
    expect(await cache.loadEvents(kinds: [1]), isEmpty);

    engine.start();
    await settled(handle);

    expect(await cache.loadEvents(kinds: [1]), hasLength(1));
  });

  test('gives the same handle to the same request', () {
    final request = SyncRequest(filters: [notes()], relays: [relay.url]);
    final other = SyncRequest(
      filters: [notes()],
      relays: [relay.url.toUpperCase().replaceFirst('WS://', 'ws://')],
    );

    expect(engine.ensure(request), engine.ensure(other));
    expect(engine.engineStatus.activeRequests, 1);
  });

  test('keeps the handle alive until every holder released it', () async {
    final request = SyncRequest(filters: [notes()], relays: [relay.url]);
    final handle = engine.ensure(request);
    engine.ensure(request);

    engine.release(handle);
    expect(engine.engineStatus.activeRequests, 1);

    engine.release(handle);
    expect(() => engine.status(handle), throwsStateError);
    expect(engine.engineStatus.activeRequests, 0);
  });

  test('reports failure when no relay answers', () async {
    await relay.stopServer();
    engine.start();

    final handle = engine.ensure(
      SyncRequest(filters: [notes()], relays: [relay.url]),
    );

    expect((await settled(handle)).phase, SyncRequestPhase.failed);
  });

  test('does not query again while coverage is fresh', () async {
    await publish(relay, 'hello');
    engine.start();

    final handle = engine.ensure(
      SyncRequest(filters: [notes()], relays: [relay.url]),
    );
    await settled(handle);

    await publish(relay, 'published later');
    engine.ensure(SyncRequest(filters: [notes()], relays: [relay.url]));
    // stop() waits for the pass this second ensure may have started.
    await engine.stop();

    expect(
      await cache.loadEvents(kinds: [1]),
      hasLength(1),
      reason: 'coverage is younger than maxStaleness, nothing to do',
    );
  });

  test('refresh goes back to the relay whatever the staleness', () async {
    await publish(relay, 'hello');
    engine.start();

    final handle = engine.ensure(
      SyncRequest(filters: [notes()], relays: [relay.url]),
    );
    await settled(handle);
    await publish(relay, 'published later');

    await engine.refresh(handle);

    expect(await cache.loadEvents(kinds: [1]), hasLength(2));
  });

  test('exposes the last page that landed', () async {
    await publish(relay, 'hello');
    engine.start();

    final handle = engine.ensure(
      SyncRequest(filters: [notes()], relays: [relay.url]),
    );

    final seen = <SyncProgress>[];
    final subscription = engine.watchStatus(handle).listen((status) {
      if (status.progress != null) seen.add(status.progress!);
    });

    await settled(handle);
    await subscription.cancel();

    expect(seen, isNotEmpty);
    expect(seen.last.relayUrl, relay.url);
    expect(engine.status(handle).progress, isNotNull);
  });

  test('queries each relay of a request on its own', () async {
    final other = MockRelay(name: 'other');
    await other.startServer();
    addTearDown(other.stopServer);

    await publish(relay, 'only on one');
    await publish(other, 'only on the other');
    engine.start();

    final handle = engine.ensure(
      SyncRequest(filters: [notes()], relays: [relay.url, other.url]),
    );
    await settled(handle);

    expect(
      (await cache.loadEvents(kinds: [1])).map((event) => event.content),
      unorderedEquals(['only on one', 'only on the other']),
      reason:
          'ndk deduplicates in flight requests by hashing the filters '
          'alone, ignoring explicitRelays. Only cacheRead being off keeps the '
          'second relay from silently receiving the first one\'s events.',
    );
  });

  test('retries a relay that was down, on its own', () async {
    final port = int.parse(relay.url.split(':').last);
    await relay.stopServer();
    engine.start();

    final handle = engine.ensure(
      SyncRequest(filters: [notes()], relays: [relay.url]),
    );
    expect((await settled(handle)).phase, SyncRequestPhase.failed);

    relay = MockRelay(name: 'engine', explicitPort: port);
    await relay.startServer();
    await publish(relay, 'published while it was down');

    expect(
      (await engine
              .watchStatus(handle)
              .firstWhere((s) => s.phase == SyncRequestPhase.synced))
          .phase,
      SyncRequestPhase.synced,
      reason: 'nobody called ensure again, the backoff timer did',
    );
    expect(await cache.loadEvents(kinds: [1]), hasLength(1));
  });

  test('stop gives up on the work in flight', () async {
    final slow = MockRelay(name: 'slow');
    await slow.startServer(delayResponse: const Duration(milliseconds: 300));
    addTearDown(slow.stopServer);

    engine.start();
    final handle = engine.ensure(
      SyncRequest(filters: [notes()], relays: [slow.url]),
    );

    await engine.stop();

    expect(engine.engineStatus.phase, SyncEnginePhase.stopped);
    expect(
      engine.status(handle).phase,
      SyncRequestPhase.idle,
      reason: 'the pass was dropped, not finished',
    );
  });

  test('a failing pass is reported once, to whoever awaits it', () async {
    final ownDb = await newDatabaseFactoryMemory().openDatabase('own.db');
    // Long enough that the retry armed by the failure stays asleep: it would
    // start a pass of its own, and nobody would be there to await that one.
    final own = SyncEngine(
      ndk,
      db: ownDb,
      initialBackoff: const Duration(minutes: 5),
    );
    addTearDown(own.dispose);

    own.start();
    final handle = own.ensure(
      SyncRequest(filters: [notes()], relays: [relay.url]),
    );
    await own
        .watchStatus(handle)
        .firstWhere((status) => status.phase == SyncRequestPhase.synced);

    await ownDb.close();

    await expectLater(own.refresh(handle), throwsA(isA<DatabaseException>()));

    // The caller took the error. A second report would land here, uncaught.
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });

  test('dispose waits for a walk whose handle was released', () async {
    final slow = MockRelay(name: 'slow');
    await slow.startServer(delayResponse: const Duration(seconds: 2));
    addTearDown(slow.stopServer);

    engine.start();
    final handle = engine.ensure(
      SyncRequest(filters: [notes()], relays: [slow.url]),
    );

    while (slow.connectedClientCount == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));

    engine.release(handle);
    await engine.dispose();
    await db.close();

    // A walk nobody can wait for would land here, writing coverage on a store
    // the caller already closed, and the test would fail on that error.
    await Future<void>.delayed(const Duration(seconds: 3));
  });

  test('a slow relay does not hold back a fast one', () async {
    final slow = MockRelay(name: 'slow');
    await slow.startServer(delayResponse: const Duration(seconds: 1));
    addTearDown(slow.stopServer);

    await publish(relay, 'from the fast relay');
    engine.start();

    final slowHandle = engine.ensure(
      SyncRequest(id: 'slow', filters: [notes()], relays: [slow.url]),
    );
    final fastHandle = engine.ensure(
      SyncRequest(id: 'fast', filters: [notes()], relays: [relay.url]),
    );

    await settled(fastHandle);

    expect(
      engine.status(slowHandle).phase,
      SyncRequestPhase.syncing,
      reason: 'the fast relay settled while the slow one is still working',
    );

    await settled(slowHandle);
  });
}
