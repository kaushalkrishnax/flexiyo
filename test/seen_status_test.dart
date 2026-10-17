import 'package:flexiyo/core/seen_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('seenStatusLabel', () {
    test('uses seconds under a minute', () {
      final now = DateTime.now();
      expect(seenStatusLabel(now), 'Seen just now');
      expect(
        seenStatusLabel(now.subtract(const Duration(seconds: 59))),
        'Seen 59s ago',
      );
      expect(
        seenStatusLabel(now.subtract(const Duration(seconds: 1))),
        'Seen 1s ago',
      );
    });

    test('uses minutes under an hour', () {
      final now = DateTime.now();
      expect(
        seenStatusLabel(now.subtract(const Duration(minutes: 1))),
        'Seen 1m ago',
      );
      expect(
        seenStatusLabel(now.subtract(const Duration(minutes: 59))),
        'Seen 59m ago',
      );
    });

    test('uses hours under a day', () {
      final now = DateTime.now();
      expect(
        seenStatusLabel(now.subtract(const Duration(hours: 3))),
        'Seen 3h ago',
      );
      expect(
        seenStatusLabel(now.subtract(const Duration(hours: 23))),
        'Seen 23h ago',
      );
    });

    test('uses days under a year', () {
      final now = DateTime.now();
      expect(
        seenStatusLabel(now.subtract(const Duration(days: 2))),
        'Seen 2d ago',
      );
      expect(
        seenStatusLabel(now.subtract(const Duration(days: 364))),
        'Seen 364d ago',
      );
    });

    test('falls back to plain "Seen" without a usable timestamp', () {
      expect(seenStatusLabel(null), 'Seen');
      expect(
        seenStatusLabel(DateTime.now().subtract(const Duration(days: 400))),
        'Seen',
      );
    });
  });
}
