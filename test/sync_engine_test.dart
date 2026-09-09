import 'package:ndk/ndk.dart';
import 'package:ndk/shared/nips/nip01/bip340.dart';
import 'package:sembast/sembast_memory.dart' hide Filter;
import 'package:sync_engine_shim_for_ndk/src/filter_fingerprint.dart';
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
      minRevisitPeriod: const Duration(milliseconds: 50),
      initialBackoff: const Duration(milliseconds: 200),
      maxBackoff: const Duration(seconds: 1),
    );
  });

  tearDown(() async {
    await engine.dispose();
    await relay.stopServer();
  });

  Future<void> publish(MockRelay target, String content, {DateTime? at}) async {
    await ndk.broadcast
        .broadcast(
          nostrEvent: Nip01Event(
            pubKey: author.publicKey,
            kind: 1,
            tags: const [],
            content: content,
            createdAt: (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000,
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

  test(
    'fills a window reaching now behind one that stops in the past',
    () async {
      final now = DateTime.now();
      int seconds(DateTime date) => date.millisecondsSinceEpoch ~/ 1000;
      await publish(relay, 'old', at: now.subtract(const Duration(days: 25)));
      await publish(relay, 'new');
      engine.start();

      final handle = engine.ensure(
        SyncRequest(
          filters: [
            notes()
              ..since = seconds(now.subtract(const Duration(days: 30)))
              ..until = seconds(now.subtract(const Duration(days: 20))),
            notes()..since = seconds(now.subtract(const Duration(days: 30))),
          ],
          relays: [relay.url],
        ),
      );
      await settled(handle);

      expect(
        await cache.loadEvents(kinds: [1]),
        hasLength(2),
        reason:
            'the first filter covers up to twenty days ago and no further, so '
            'the second must still walk from there to now',
      );
    },
  );

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

  test('gives a handle of its own to each window', () {
    SyncRequest window(int since, int until) => SyncRequest(
      filters: [
        notes()
          ..since = since
          ..until = until,
      ],
      relays: [relay.url],
    );

    expect(
      engine.ensure(window(1672531200, 1704067200)),
      isNot(engine.ensure(window(1735689600, 1767225600))),
    );
    expect(engine.engineStatus.activeRequests, 2);
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

  test('syncs a gated relay as the account the request names', () async {
    final gated = MockRelay(name: 'gated', requireAuthForRequests: true);
    await gated.startServer();
    addTearDown(gated.stopServer);
    await publish(gated, 'hello');

    ndk.accounts.loginPrivateKey(
      pubkey: author.publicKey,
      privkey: author.privateKey!,
    );
    engine.start();

    final handle = engine.ensure(
      SyncRequest(
        filters: [notes()],
        relays: [gated.url],
        authPubkey: author.publicKey,
      ),
    );

    expect((await settled(handle)).phase, SyncRequestPhase.synced);
    expect(gated.connectionsAuthenticatedAs(author.publicKey), 1);
    expect(await cache.loadEvents(kinds: [1]), hasLength(1));
  });

  test('reads nothing when ndk has no account for the request', () async {
    await publish(relay, 'hello');
    engine.start();

    final handle = engine.ensure(
      SyncRequest(
        filters: [notes()],
        relays: [relay.url],
        authPubkey: author.publicKey,
      ),
    );
    final status = await settled(handle);

    expect(status.phase, SyncRequestPhase.failed);
    expect(
      status.lastError,
      isA<SyncAuthUnavailable>()
          .having((error) => error.pubkey, 'pubkey', author.publicKey)
          .having(
            (error) => error.reason,
            'reason',
            SyncAuthFailure.unknownAccount,
          ),
    );
    expect(
      relay.subscriptionsRequestedOutside(author.publicKey),
      isEmpty,
      reason: 'reading anonymously would file the answers under that pubkey',
    );
    expect(status.relayStates, isEmpty);
    expect(await cache.loadEvents(kinds: [1]), isEmpty);
  });

  test('reads nothing when the named account cannot sign', () async {
    await publish(relay, 'hello');
    ndk.accounts.loginPublicKey(pubkey: author.publicKey);
    engine.start();

    final handle = engine.ensure(
      SyncRequest(
        filters: [notes()],
        relays: [relay.url],
        authPubkey: author.publicKey,
      ),
    );
    final status = await settled(handle);

    expect(status.phase, SyncRequestPhase.failed);
    expect(
      status.lastError,
      isA<SyncAuthUnavailable>().having(
        (error) => error.reason,
        'reason',
        SyncAuthFailure.cannotSign,
      ),
    );
    expect(relay.subscriptionsRequestedOutside(author.publicKey), isEmpty);
  });

  test('picks up the account on its own once it appears', () async {
    final gated = MockRelay(name: 'gated', requireAuthForRequests: true);
    await gated.startServer();
    addTearDown(gated.stopServer);
    await publish(gated, 'hello');

    engine.start();
    final handle = engine.ensure(
      SyncRequest(
        filters: [notes()],
        relays: [gated.url],
        authPubkey: author.publicKey,
        maxStaleness: Duration.zero,
      ),
    );

    expect((await settled(handle)).phase, SyncRequestPhase.failed);

    final synced = engine
        .watchStatus(handle)
        .firstWhere((status) => status.phase == SyncRequestPhase.synced);
    ndk.accounts.loginPrivateKey(
      pubkey: author.publicKey,
      privkey: author.privateKey!,
    );

    expect(
      (await synced).lastError,
      isNull,
      reason: 'a request declared before the login recovers by itself',
    );
    expect(gated.connectionsAuthenticatedAs(author.publicKey), 1);
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

  test('forget walks a held request back from scratch', () async {
    await publish(relay, 'hello');
    engine.start();

    final request = SyncRequest(filters: [notes()], relays: [relay.url]);
    final handle = engine.ensure(request);
    await settled(handle);

    await publish(relay, 'published later');
    await engine.forget(request);
    // forget restarted the pass, and the handle is syncing.
    await settled(handle);

    expect(
      await cache.loadEvents(kinds: [1]),
      hasLength(2),
      reason: 'the coverage is gone, the relay is asked again',
    );
  });

  test(
    'forget drops the coverage of a released request, on its relays only',
    () async {
      final other = MockRelay(name: 'other');
      await other.startServer();
      addTearDown(other.stopServer);

      engine.start();
      final handle = engine.ensure(
        SyncRequest(filters: [notes()], relays: [relay.url, other.url]),
      );
      await settled(handle);
      engine.release(handle);

      await engine.forget(SyncRequest(filters: [notes()], relays: [relay.url]));

      Future<RelayFilterSyncState?> stateOn(String relayUrl) =>
          engine.store.readSyncState(
            relayUrl: relayUrl,
            filterFingerprint: filterFingerprint(notes()),
          );
      expect(await stateOn(relay.url), isNull);
      expect(await stateOn(other.url), isNotNull);
    },
  );

  test('clearAllLocalData forgets the coverage and fetches again', () async {
    await publish(relay, 'hello');
    engine.start();

    final handle = engine.ensure(
      SyncRequest(filters: [notes()], relays: [relay.url]),
    );
    await settled(handle);

    await publish(relay, 'published later');
    await engine.clearAllLocalData();
    // The restart kicked off a pass, and the handle is syncing.
    await settled(handle);

    expect(
      await cache.loadEvents(kinds: [1]),
      hasLength(2),
      reason: 'the coverage is gone, the relay is asked again',
    );
  });

  test('clearAllLocalData leaves a stopped engine stopped', () async {
    await engine.store.writeSyncState(
      RelayFilterSyncState(relayUrl: relay.url, filterFingerprint: 'abc'),
    );

    await engine.clearAllLocalData();

    expect(
      await engine.store.readSyncState(
        relayUrl: relay.url,
        filterFingerprint: 'abc',
      ),
      isNull,
    );
    expect(engine.engineStatus.phase, SyncEnginePhase.stopped);
  });

  test('clearAllLocalData waits for a walk in flight', () async {
    final slow = MockRelay(name: 'slow');
    await slow.startServer(delayResponse: const Duration(seconds: 2));
    addTearDown(slow.stopServer);

    engine.start();
    engine.ensure(SyncRequest(filters: [notes()], relays: [slow.url]));

    while (slow.connectedClientCount == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final clock = Stopwatch()..start();
    await engine.clearAllLocalData();
    await engine.stop();

    expect(
      clock.elapsed,
      greaterThan(const Duration(seconds: 1)),
      reason: 'the page in flight landed before the store was emptied',
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

  Future<int> cachedWithin(int expected, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    var events = await cache.loadEvents(kinds: [1]);

    while (events.length < expected && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      events = await cache.loadEvents(kinds: [1]);
    }

    return events.length;
  }

  test('goes back to the relay on its own once coverage went stale', () async {
    await publish(relay, 'hello');
    engine.start();

    final handle = engine.ensure(
      SyncRequest(
        filters: [notes()],
        relays: [relay.url],
        maxStaleness: const Duration(milliseconds: 200),
      ),
    );
    await settled(handle);
    await publish(relay, 'published later');

    expect(
      await cachedWithin(2, const Duration(seconds: 5)),
      2,
      reason: 'nobody called ensure again, the tick did',
    );
  });

  test('never revisits faster than the engine can poll', () async {
    final slowFloor = SyncEngine(
      ndk,
      db: db,
      minRevisitPeriod: const Duration(seconds: 30),
    );
    addTearDown(slowFloor.dispose);

    await publish(relay, 'hello');
    slowFloor.start();

    final handle = slowFloor.ensure(
      SyncRequest(
        filters: [notes()],
        relays: [relay.url],
        maxStaleness: Duration.zero,
      ),
    );
    await slowFloor
        .watchStatus(handle)
        .firstWhere((status) => status.phase == SyncRequestPhase.synced);

    final passes = <SyncRequestPhase>[];
    final subscription = slowFloor.watchStatus(handle).listen((status) {
      if (status.phase == SyncRequestPhase.syncing) passes.add(status.phase);
    });
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await subscription.cancel();

    expect(
      passes,
      isEmpty,
      reason:
          'a request asking never to be stale asks for a subscription, and '
          'the floor is what the engine answers instead of spinning',
    );
  });

  test('does not tick while the engine is stopped', () async {
    await publish(relay, 'hello');
    engine.start();

    final handle = engine.ensure(
      SyncRequest(
        filters: [notes()],
        relays: [relay.url],
        maxStaleness: const Duration(milliseconds: 200),
      ),
    );
    await settled(handle);
    await engine.stop();
    await publish(relay, 'published later');

    expect(
      await cachedWithin(2, const Duration(milliseconds: 800)),
      1,
      reason: 'a backgrounded app spends nothing on the network',
    );
  });

  test('stops ticking on a window that closed and is covered', () async {
    final now = DateTime.now();
    int seconds(DateTime date) => date.millisecondsSinceEpoch ~/ 1000;
    await publish(relay, 'inside', at: now.subtract(const Duration(hours: 3)));
    engine.start();

    final handle = engine.ensure(
      SyncRequest(
        filters: [
          notes()
            ..since = seconds(now.subtract(const Duration(hours: 4)))
            ..until = seconds(now.subtract(const Duration(hours: 2))),
        ],
        relays: [relay.url],
        maxStaleness: const Duration(milliseconds: 200),
      ),
    );
    await settled(handle);
    await publish(
      relay,
      'landed late',
      at: now.subtract(const Duration(hours: 3)),
    );

    final passes = <SyncRequestPhase>[];
    final subscription = engine.watchStatus(handle).listen((status) {
      if (status.phase == SyncRequestPhase.syncing) passes.add(status.phase);
    });
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await subscription.cancel();

    expect(
      passes,
      hasLength(lessThanOrEqualTo(1)),
      reason:
          'four periods went by: a request over a closed window it covered to '
          'the end has nothing left to come back for, and stops ticking',
    );
    expect(await cache.loadEvents(kinds: [1]), hasLength(1));
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

  test('does not retry a relay that refused the request', () async {
    relay.closeRequestsMessage = 'blocked: not for you';
    engine.start();

    final handle = engine.ensure(
      SyncRequest(filters: [notes()], relays: [relay.url]),
    );
    expect((await settled(handle)).phase, SyncRequestPhase.failed);

    // Nothing authenticates here, so this is every REQ the relay ever saw.
    final requested = relay.subscriptionsRequestedOutside(author.publicKey);
    await Future<void>.delayed(const Duration(milliseconds: 800));

    expect(
      relay.subscriptionsRequestedOutside(author.publicKey),
      requested,
      reason:
          'a refusal arms no backoff: the relay is up and would only refuse '
          'again, and counting it would slow down the windows it does serve',
    );
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
