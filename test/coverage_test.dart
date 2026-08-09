import 'package:sync_engine_shim_for_ndk/src/coverage.dart';
import 'package:sync_engine_shim_for_ndk/src/entities/relay_filter_sync_state.dart';
import 'package:test/test.dart';

final april = DateTime.utc(2026, 4, 1);
final june = DateTime.utc(2026, 6, 1);

CoverageRange range(DateTime from, DateTime to, DateTime completedAt) =>
    CoverageRange(from: from, to: to, completedAt: completedAt);

DateTime day(int month, int dayOfMonth) =>
    DateTime.utc(2026, month, dayOfMonth);

DateTime endOf(int month, int dayOfMonth) =>
    DateTime.utc(2026, month, dayOfMonth, 23, 59, 59);

void main() {
  group('addRange', () {
    test('inserts into an empty coverage', () {
      final result = addRange([], range(day(1, 1), endOf(1, 31), april));

      expect(result, [range(day(1, 1), endOf(1, 31), april)]);
    });

    test(
      'splits an overlapping range and keeps its completedAt on the sides',
      () {
        final coverage = [range(day(1, 1), endOf(3, 31), april)];

        final result = addRange(coverage, range(day(2, 1), endOf(2, 28), june));

        expect(result, [
          range(day(1, 1), endOf(1, 31), april),
          range(day(2, 1), endOf(2, 28), june),
          range(day(3, 1), endOf(3, 31), april),
        ]);
      },
    );

    test('merges contiguous ranges sharing a completedAt', () {
      final coverage = [range(day(1, 1), endOf(1, 31), april)];

      final result = addRange(coverage, range(day(2, 1), endOf(2, 28), april));

      expect(result, [range(day(1, 1), endOf(2, 28), april)]);
    });

    test('keeps contiguous ranges with different completedAt apart', () {
      final coverage = [range(day(1, 1), endOf(1, 31), april)];

      final result = addRange(coverage, range(day(2, 1), endOf(2, 28), june));

      expect(result, [
        range(day(1, 1), endOf(1, 31), april),
        range(day(2, 1), endOf(2, 28), june),
      ]);
    });

    test('replaces a fully covered range', () {
      final coverage = [range(day(2, 1), endOf(2, 28), april)];

      final result = addRange(coverage, range(day(1, 1), endOf(3, 31), june));

      expect(result, [range(day(1, 1), endOf(3, 31), june)]);
    });

    test('trims an overlap on the left', () {
      final coverage = [range(day(1, 1), endOf(2, 28), april)];

      final result = addRange(coverage, range(day(2, 1), endOf(3, 31), june));

      expect(result, [
        range(day(1, 1), endOf(1, 31), april),
        range(day(2, 1), endOf(3, 31), june),
      ]);
    });

    test('trims an overlap on the right', () {
      final coverage = [range(day(2, 1), endOf(3, 31), april)];

      final result = addRange(coverage, range(day(1, 1), endOf(2, 28), june));

      expect(result, [
        range(day(1, 1), endOf(2, 28), june),
        range(day(3, 1), endOf(3, 31), april),
      ]);
    });

    test('keeps ranges apart when a second is missing between them', () {
      final second = DateTime.utc(2026, 1, 1, 0, 0);
      final coverage = [range(second, second.add(Duration(seconds: 5)), april)];

      final result = addRange(
        coverage,
        range(
          second.add(Duration(seconds: 7)),
          second.add(Duration(seconds: 10)),
          april,
        ),
      );

      expect(result, [
        range(second, second.add(Duration(seconds: 5)), april),
        range(
          second.add(Duration(seconds: 7)),
          second.add(Duration(seconds: 10)),
          april,
        ),
      ]);
      expect(
        findGaps(result, from: second, to: second.add(Duration(seconds: 10))),
        [
          (
            from: second.add(Duration(seconds: 6)),
            to: second.add(Duration(seconds: 6)),
          ),
        ],
      );
    });

    test('does not grow when the same range is added twice', () {
      final added = range(day(1, 1), endOf(1, 31), april);

      final result = addRange(addRange([], added), added);

      expect(result, [added]);
    });
  });

  group('findGaps', () {
    test('returns the whole period when coverage is empty', () {
      final gaps = findGaps([], from: day(1, 1), to: endOf(3, 31));

      expect(gaps, [(from: day(1, 1), to: endOf(3, 31))]);
    });

    test('returns nothing when the period is covered', () {
      final coverage = [range(day(1, 1), endOf(3, 31), april)];

      final gaps = findGaps(coverage, from: day(2, 1), to: endOf(2, 28));

      expect(gaps, isEmpty);
    });

    test('returns the hole between two ranges', () {
      final coverage = [
        range(day(1, 1), endOf(1, 31), april),
        range(day(3, 1), endOf(3, 31), april),
      ];

      final gaps = findGaps(coverage, from: day(1, 1), to: endOf(3, 31));

      expect(gaps, [(from: day(2, 1), to: endOf(2, 28))]);
    });

    test('returns the edges left uncovered', () {
      final coverage = [range(day(2, 1), endOf(2, 28), april)];

      final gaps = findGaps(coverage, from: day(1, 1), to: endOf(3, 31));

      expect(gaps, [
        (from: day(1, 1), to: endOf(1, 31)),
        (from: day(3, 1), to: endOf(3, 31)),
      ]);
    });

    test('ignores coverage outside the period', () {
      final coverage = [
        range(day(1, 1), endOf(1, 31), april),
        range(day(6, 1), endOf(6, 30), april),
      ];

      final gaps = findGaps(coverage, from: day(2, 1), to: endOf(2, 28));

      expect(gaps, [(from: day(2, 1), to: endOf(2, 28))]);
    });
  });
}
