## Unreleased

- Coverage is only recorded when the relay sent an EOSE. An empty answer used
  to be the proof that a relay had nothing left, and a relay refusing a request
  returns no events either: the window was marked covered without a single
  event being read, and covered ground is never fetched again.
- A relay ending a request with a CLOSED is told apart from an unreachable one,
  and leaves its backoff untouched. It is up and answering, only not this
  request, so a retry would be refused again, and the backoff is per relay:
  counting a refusal would slow down the windows that relay does serve.
- Depend on `ndk` 0.10.0-dev.1, which reports what each relay did with a
  request. The timeout and connectivity heuristics that stood in for it are
  gone.

## 0.5.0

- `SyncEngine.clearAllLocalData` forgets everything the engine persisted, for
  a full app reset. Local only, the NDK cache is the app's to clear. A cache
  emptied under a coverage that survived was never fetched again.
- `SyncEngine.forget` does the same for one request, held or not. This is how
  an app scopes the cleanup to one account: authors are hashed into the
  fingerprint, so the engine cannot do it on its own.

## 0.4.0

- A held request now revisits its windows on its own, every `maxStaleness`, for
  as long as the engine is started. `ensure` meant *keep this available* but
  only ever filled what was missing at the moment it was called: staying up to
  date was left to an app writing a timer of its own. `maxStaleness` is now
  both the freshness asked for and the period paid for. `stop` stops the
  ticking, `start` picks it up.
- `SyncEngine` takes a `minRevisitPeriod`, 15 seconds by default. Under it a
  poll is a subscription written the wrong way round, and the engine cannot
  subscribe yet, so a shorter `maxStaleness` is honoured as this floor rather
  than spinning.
- A window whose `until` is in the past no longer goes stale once it is covered
  to its end, and a request whose windows have all closed stops going back to
  the relays. An archive was refetching its trailing overlap on every pass, and
  would have been polled for good. `refresh` still reopens it.

## 0.3.2

- Staleness is measured on the coverage nearest the end of the window being
  planned, rather than on the whole coverage of the filter, and only coverage
  that reached the end of the window it ran in has a say. Windows sharing a
  fingerprint share a coverage list, so a backfill bounded in 2024 marked
  everything after it as freshly validated and it was never fetched.
- A request is identified by its windows too, not only by its filters and
  relays. Asking for the same filter over two periods gave the same handle
  back, and the second set of filters was silently dropped. A filter whose
  `since` moves between two calls now yields a handle of its own, where it used
  to join the previous one.

## 0.3.1

- `stop` and `dispose` wait for a walk whose handle was released mid pass.
  Releasing dropped the registration, and with it the only way to reach the
  pass still running: it kept reading and writing the store after the caller
  closed the database.
- A relay retry armed while `stop` was waiting is now cancelled too, instead of
  outliving the call.

## 0.3.0

- Depend on `ndk` 0.9.0.

## 0.2.0

- `SyncRequestStatus` carries a `progress`, the last page that landed: relay,
  filter fingerprint, the period it closed and how many events it returned. The
  status is now emitted on every page rather than twice per pass.

## 0.1.1

- Never send a negative `since` to a relay. A window opening at the epoch, or a
  `since` pushed under it by the overlap margin, used to produce a negative
  timestamp. A filter asks for everything by leaving `since` out.

## 0.1.0

- Initial version.
