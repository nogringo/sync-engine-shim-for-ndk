import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:ndk/ndk.dart';

/// Identity of the logical filter, stable across pagination: `since`, `until`
/// and `limit` move on every request without changing what is being asked for.
///
/// Order never matters, so a filter listing the same authors in another order
/// keeps its fingerprint. Empty lists are treated as absent, like ndk does.
String filterFingerprint(Filter filter) {
  final canonical = <String, Object>{};

  void put(String key, List<String>? values) {
    if (values == null || values.isEmpty) return;
    canonical[key] = List<String>.from(values)..sort();
  }

  put('ids', filter.ids);
  put('authors', filter.authors);

  final kinds = filter.kinds;
  if (kinds != null && kinds.isNotEmpty) {
    canonical['kinds'] = List<int>.from(kinds)..sort();
  }

  final search = filter.search;
  if (search != null) canonical['search'] = search;

  final tags = filter.tags;
  if (tags != null && tags.isNotEmpty) {
    final sortedTags = <String, List<String>>{};
    for (final key in tags.keys.toList()..sort()) {
      final values = tags[key];
      if (values == null || values.isEmpty) continue;
      sortedTags[key] = List<String>.from(values)..sort();
    }
    if (sortedTags.isNotEmpty) canonical['tags'] = sortedTags;
  }

  final digest = sha256.convert(utf8.encode(jsonEncode(canonical)));
  return digest.toString().substring(0, 16);
}
