import 'package:ndk/ndk.dart';
import 'package:sync_engine_shim_for_ndk/src/filter_fingerprint.dart';
import 'package:test/test.dart';

const alice =
    '56e8c688aabb49e9bb68f9d8d6722c809366ad1ad959042db45970cc63152d75';
const bob = '3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d';

void main() {
  test('is 16 hex characters', () {
    final fingerprint = filterFingerprint(Filter(kinds: [1]));

    expect(fingerprint, matches(RegExp(r'^[0-9a-f]{16}$')));
  });

  test('ignores pagination fields', () {
    final base = Filter(kinds: [1], authors: [alice]);
    final paginated = Filter(
      kinds: [1],
      authors: [alice],
      since: 1700000000,
      until: 1800000000,
      limit: 50,
    );

    expect(filterFingerprint(paginated), filterFingerprint(base));
  });

  test('ignores the order of authors and kinds', () {
    final one = Filter(kinds: [1, 7], authors: [alice, bob]);
    final other = Filter(kinds: [7, 1], authors: [bob, alice]);

    expect(filterFingerprint(other), filterFingerprint(one));
  });

  test('ignores the order of tags and of their values', () {
    final one = Filter(kinds: [1], pTags: [alice, bob], tTags: ['nostr']);
    final other = Filter(kinds: [1], tTags: ['nostr'], pTags: [bob, alice]);

    expect(filterFingerprint(other), filterFingerprint(one));
  });

  test('treats an empty list as absent', () {
    final withEmpty = Filter(kinds: [1], authors: []);

    expect(filterFingerprint(withEmpty), filterFingerprint(Filter(kinds: [1])));
  });

  test('separates filters that ask for different things', () {
    final notes = filterFingerprint(Filter(kinds: [1], authors: [alice]));
    final reactions = filterFingerprint(Filter(kinds: [7], authors: [alice]));
    final otherAuthor = filterFingerprint(Filter(kinds: [1], authors: [bob]));
    final tagged = filterFingerprint(Filter(kinds: [1], pTags: [alice]));

    expect({notes, reactions, otherAuthor, tagged}, hasLength(4));
  });

  test('separates a search from the same filter without one', () {
    final searching = filterFingerprint(Filter(kinds: [1], search: 'nostr'));

    expect(searching, isNot(filterFingerprint(Filter(kinds: [1]))));
  });
}
