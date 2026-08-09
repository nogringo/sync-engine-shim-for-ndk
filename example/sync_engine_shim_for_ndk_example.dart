import 'package:ndk/ndk.dart';
import 'package:sembast/sembast_memory.dart' hide Filter;
import 'package:sync_engine_shim_for_ndk/sync_engine_shim_for_ndk.dart';

const somePubkey =
    '56e8c688aabb49e9bb68f9d8d6722c809366ad1ad959042db45970cc63152d75';

Future<void> main() async {
  final db = await databaseFactoryMemory.openDatabase('sync_engine.db');

  final ndk = Ndk(
    NdkConfig(
      eventVerifier: Bip340EventVerifier(),
      cache: MemCacheManager(),
    ),
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

  engine.watchStatus(handle).listen((status) {
    print('sync phase: ${status.phase}');
  });

  // Synced events land in the NDK cache, read them from there.
  final notes = await ndk.requests.query(filter: filter).future;
  print('${notes.length} notes');

  engine.release(handle);
}
