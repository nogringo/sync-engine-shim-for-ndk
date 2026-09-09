import 'package:ndk/ndk.dart';

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
  final List<String> relays;

  /// Identity to authenticate as (NIP-42), resolved against `ndk.accounts` when
  /// the request runs. Coverage is filed under it, apart from the anonymous
  /// one. A request naming nobody never authenticates.
  final String? authPubkey;

  /// Overrides the engine default. A profile goes stale slower than a feed.
  final Duration? maxStaleness;

  final Duration? overlapMargin;
}
