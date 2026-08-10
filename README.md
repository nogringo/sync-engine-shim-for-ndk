# sync_engine_shim_for_ndk

Downward sync engine for the [ndk](https://pub.dev/packages/ndk) package.

You declare what you want available locally. The engine works out what is
missing, fetches it from each relay, and remembers what it already covered so a
restart does not fetch it twice. Your app never writes a request, never paginates
and never tracks a `since`.

Nothing goes up: this package only synchronises downwards, it never broadcasts.

## Quick start

```dart
import 'package:ndk/ndk.dart';
import 'package:sembast/sembast_io.dart' hide Filter;
import 'package:sync_engine_shim_for_ndk/sync_engine_shim_for_ndk.dart';

Future<void> main() async {
  final db = await databaseFactoryIo.openDatabase('sync_engine.db');

  final cache = await SembastCacheManager.create(databasePath: '.');
  final ndk = Ndk(
    NdkConfig(eventVerifier: Bip340EventVerifier(), cache: cache),
  );

  final engine = SyncEngine(ndk, db: db);
  engine.start();

  final handle = engine.ensure(
    SyncRequest(
      filters: [Filter(kinds: [1], authors: [myPubkey])],
      relays: const ['wss://relay.damus.io', 'wss://nos.lol'],
    ),
  );

  engine.watchStatus(handle).listen((status) => print(status.phase));
}
```

`sembast` exports a `Filter` of its own, hence the `hide Filter` on its import.

## Reading the events

You don't, not from this package. Synced events land in the NDK cache you
configured, and that cache is where your app reads:

```dart
final notes = await cache.loadEvents(kinds: [1], pubKeys: [myPubkey]);
```

The engine returns handles and statuses, never events. It has one job: making
sure the cache holds what you asked for.

## ensure, refresh, release

`ensure` is a declaration, not a command: *keep this available locally*. It is
cheap to call repeatedly, from a widget build or an `initState`, because it only
goes to the relays when something is actually missing or stale. Calling it twice
with the same filters and relays gives the same handle back, whatever the order
of the lists.

`refresh` is the pull to refresh gesture: go and look now, however fresh the
coverage is.

`watchStatus` carries the phase, and `progress` holds the last page that landed:
which relay, which filter, the period it closed and how many events it returned.
It is a sign of life during a long walk, not a percentage, and its count is a
rate rather than an inventory since the second at the boundary of two pages is
asked twice.

`release` drops your interest in a handle. A handle survives until its last
holder releases it, and what was synced stays in the database either way. A walk
still running stops at its next page, so leaving a screen stops spending network
on it. Same for `stop`, which drops what is in flight instead of waiting it out.

## How far back, and how often

How far back a request reaches is bounded by each filter's own `since`. Without
one, the engine walks back until a relay says it has nothing older, which for a
broad filter is a lot of events.

Two durations drive the rest, given to the engine and overridable per request:

```dart
SyncEngine(
  ndk,
  db: db,
  maxStaleness: const Duration(minutes: 5), // before the recent end is revisited
  overlapMargin: const Duration(days: 1),   // how far back a window reaches beyond
);                                          // what is strictly missing
```

`maxStaleness` is measured on when the coverage was last validated, not on how
far it reaches. Coverage brought right up to the present still goes stale.

`overlapMargin` exists because an event can reach a relay long after its
`created_at`. Refetching a little further back than necessary is what catches
those.

## Gift wraps

NIP-59 randomises a gift wrap's `created_at` up to two days into the past, so an
event received today can carry the timestamp of the day before yesterday. Any
window on kind 1059 therefore reaches two extra days back, automatically. You
have nothing to declare, it follows from the filter's kinds.

## Relays

One query per relay, and one at a time per relay. Relays run in parallel, so a
slow relay never holds back a fast one, and a relay wanted by several requests
still sees a single query at a time rather than one per request.

Coverage is tracked per relay, which is what lets the engine ask a lagging relay
for exactly what it missed rather than replaying everything everywhere.

A relay that leaves something unanswered is retried on its own, after a backoff
that doubles from `initialBackoff` up to `maxBackoff` and resets the moment that
relay answers. Your app has nothing to call back: a request that failed while
the train was in a tunnel recovers by itself. The backoff lives in memory, so
restarting tries again straight away.

## What it does not do yet

- **No live subscription.** New events show up on a later `ensure`, once the
  coverage went stale, or right away on a `refresh`.
- **No broadcast.** Downwards only.
- **No NIP-42 authentication.** `SyncRequest.authPubkey` only keeps the sync
  state of an authenticated relay separate from the anonymous one, it does not
  authenticate anything yet.
- **The filter's `limit` is ignored.** It is not part of what identifies a
  filter, so honouring it would let a capped request mark a window as covered
  and leave an uncapped one believing there is nothing left to fetch.

## License

MIT
