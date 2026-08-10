## 0.1.1

- Never send a negative `since` to a relay. A window opening at the epoch, or a
  `since` pushed under it by the overlap margin, used to produce a negative
  timestamp. A filter asks for everything by leaving `since` out.

## 0.1.0

- Initial version.
