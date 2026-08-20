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
