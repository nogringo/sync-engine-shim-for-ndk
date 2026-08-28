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
