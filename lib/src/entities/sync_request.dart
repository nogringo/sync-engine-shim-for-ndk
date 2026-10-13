import 'package:ndk/ndk.dart';
import 'package:url_set_for_ndk/url_set_for_ndk.dart';

/// What the caller wants kept available in the cache: a set of filters, on a
/// set of relays. Each filter's `since` bounds how far back the engine goes.
class SyncRequest {
  const SyncRequest({
    this.id,
    required this.filters,
    required this.relays,
    this.authPubkey,
    this.maxStaleness,
    this.overlapMargin,
  });

  /// Stable caller-provided identity. Two requests sharing an id share a handle.
  final String? id;

  final List<Filter> filters;

  /// Where to sync from. A set that reads lists, like `UrlSet.dm(me)`, is
  /// resolved again on every pass, so the request follows the list when it
  /// changes. Blossom servers are refused.
  final UrlSet relays;

  /// Identity to authenticate as (NIP-42), resolved through
  /// `SyncEngine.signerFor` when the request runs. Coverage is filed under it,
  /// apart from the anonymous one. A request naming nobody never authenticates.
  final String? authPubkey;

  /// Overrides the engine default. A profile goes stale slower than a feed.
  final Duration? maxStaleness;

  final Duration? overlapMargin;
}
