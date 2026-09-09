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

`ensure` is a declaration, not a command: *keep this available locally, and keep
it up to date*. It is cheap to call repeatedly, from a widget build or an
`initState`, because it only goes to the relays when something is actually
missing or stale. Calling it twice with the same filters and relays gives the
same handle back, whatever the order of the lists.

Once the backfill is done the engine keeps going on its own, revisiting the
recent end of every window it holds. Your app has no timer to write: what it
declared stays true without it asking again.

`refresh` is the pull to refresh gesture: go and look now, however fresh the
coverage is.

`watchStatus` carries the phase, and `progress` holds the last page that landed:
which relay, which filter, the period it closed and how many events it returned.
It is a sign of life during a long walk, not a percentage, and its count is a
rate rather than an inventory since the second at the boundary of two pages is
asked twice.

`release` drops your interest in a handle. A handle survives until its last
holder releases it, and what was synced stays in the database either way. A walk
still running stops at its next page, and the request stops revisiting, so
leaving a screen stops spending network on it. Same for `stop`, which drops what
is in flight instead of waiting it out: that is what an app going to the
background calls, and `start` picks the ticking back up.

`forget` drops what was synced for a request, so its next pass walks it back
from scratch. It takes the request rather than a handle: the time to forget is
after the last screen released it, as when an account is removed. Coverage is
per filter and relay, not per window, so every window of those filters on those
relays goes.

`clearAllLocalData` forgets everything the engine persisted: that is what a full
app reset calls. Held handles start over.

Both are local only. The NDK cache is yours, so clear it too, and clear both or
none: a cache emptied under a coverage that survived is never fetched again.

## How far back, and how often

How far back a request reaches is bounded by each filter's own `since`. Without
one, the engine walks back until a relay says it has nothing older, which for a
broad filter is a lot of events.

A filter's `until` closes the other end, which is how a request asks for a past
period rather than for everything up to now. Two periods are two filters, or two
requests: the window is part of what identifies a request, so different windows
never collapse onto the same handle.

```dart
int at(DateTime date) => date.millisecondsSinceEpoch ~/ 1000;

engine.ensure(
  SyncRequest(
    filters: [
      Filter(kinds: [1], since: at(DateTime.utc(2023)), until: at(DateTime.utc(2024))),
      Filter(kinds: [1], since: at(DateTime.utc(2025)), until: at(DateTime.utc(2026))),
    ],
    relays: const ['wss://relay.damus.io'],
  ),
);
```

Two durations drive the rest, given to the engine and overridable per request:

```dart
SyncEngine(
  ndk,
  db: db,
  maxStaleness: const Duration(minutes: 5), // how often the recent end is revisited
  overlapMargin: const Duration(days: 1),   // how far back a window reaches beyond
);                                          // what is strictly missing
```

`maxStaleness` is measured on when the coverage was last validated, not on how
far it reaches. Coverage brought right up to the present still goes stale, and
that is what the engine goes back for: a held request revisits its windows every
`maxStaleness`, so the cache is never further behind the relays than that. It is
the freshness you ask for and the period you pay for, in one number.

`overlapMargin` exists because an event can reach a relay long after its
`created_at`. Refetching a little further back than necessary is what catches
those.

A third duration is the floor under all this:

```dart
SyncEngine(ndk, db: db, minRevisitPeriod: const Duration(seconds: 15));
```

Asking to be fresher than that is asking for a subscription, which this package
does not hold yet, and answering it with a faster poll would only be a bad
imitation of one. So a shorter `maxStaleness` is honoured as `minRevisitPeriod`,
`Duration.zero` included. Lower the floor if you know what you are asking your
relays for. It goes away the day the engine learns to subscribe.

## Windows that close

Nothing of this outlives a window. A filter whose `until` is in the past, once
covered to its end, is finished: it never goes stale again, and the request
stops going back to the relays once its last window has closed. An archive is
not something to poll.

That means a note published at 23:59 but reaching the relay at 00:05 is missed
by a window closing at midnight. `refresh` is the way back in, and it ignores
this rule like it ignores `maxStaleness`.

A window reaching into the future is open, so `until` set to tonight keeps
ticking all day and closes itself when the day is over.

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

## Authenticating

`SyncRequest.authPubkey` names the identity a request goes out under. It is
looked up in `ndk.accounts` when the request runs, not when it is registered, so
a request declared before the login is not lost: it authenticates on its next
pass, within `maxStaleness`. Nothing watches for the login, so `refresh` is what
turns that wait into nothing. Coverage stays filed under that pubkey, separate
from the anonymous one, since a relay may well serve two different things.

A request that names nobody never sends an AUTH, whoever happens to be logged
in. A request that names a pubkey ndk cannot sign with reads nothing at all: it
reports a `SyncAuthUnavailable` on `SyncRequestStatus.lastError` and leaves the
relay alone, rather than reading anonymously and filing the answers under an
identity that never signed for them.

## What it does not do yet

- **No live subscription.** The engine polls, it does not hold a subscription
  open, so a new event lands within `maxStaleness` rather than the second it is
  signed, and never faster than `minRevisitPeriod`. `refresh` is there for when
  that wait is too long.
- **No broadcast.** Downwards only.
- **The filter's `limit` is ignored.** It is not part of what identifies a
  filter, so honouring it would let a capped request mark a window as covered
  and leave an uncapped one believing there is nothing left to fetch.

## License

MIT
