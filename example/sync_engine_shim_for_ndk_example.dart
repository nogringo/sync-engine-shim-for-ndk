import 'package:ndk/ndk.dart';
import 'package:sembast/sembast_memory.dart' hide Filter;
import 'package:sync_engine_shim_for_ndk/sync_engine_shim_for_ndk.dart';

const somePubkey =
    '56e8c688aabb49e9bb68f9d8d6722c809366ad1ad959042db45970cc63152d75';

Future<void> main() async {
  final db = await databaseFactoryMemory.openDatabase('sync_engine.db');

  final cache = MemCacheManager();
  final ndk = Ndk(
    NdkConfig(eventVerifier: Bip340EventVerifier(), cache: cache),
  );

  final engine = SyncEngine(ndk, db: db);
  engine.start();

  final filter = Filter(kinds: [1], authors: [somePubkey]);

  final handle = engine.ensure(
    SyncRequest(
      filters: [filter],
      relays: const ['wss://relay.damus.io', 'wss://nos.lol'],
    ),
  );

  await engine
      .watchStatus(handle)
      .firstWhere(
        (status) =>
            status.phase == SyncRequestPhase.synced ||
            status.phase == SyncRequestPhase.failed,
      );

  // Synced events land in the NDK cache, read them from there.
  final notes = await cache.loadEvents(kinds: [1], pubKeys: [somePubkey]);
  print('${notes.length} notes');

  engine.release(handle);
  await engine.dispose();
  ndk.destroy();
}
