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
