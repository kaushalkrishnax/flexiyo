import 'package:flexiyo/screens/conversation/scroll_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isAtBottom', () {
    test('follows new messages near the bottom', () {
      expect(isAtBottom(pixels: 920, maxScrollExtent: 1000), isTrue);
      expect(isAtBottom(pixels: 1000, maxScrollExtent: 1000), isTrue);
    });

    test('stops following once the reader scrolls away', () {
      expect(isAtBottom(pixels: 900, maxScrollExtent: 1000), isFalse);
      expect(isAtBottom(pixels: 0, maxScrollExtent: 1000), isFalse);
    });
  });

  group('shouldLoadOlder', () {
    test('loads a page at the top', () {
      expect(shouldLoadOlder(pixels: 0, minScrollExtent: 0), isTrue);
      expect(shouldLoadOlder(pixels: 100, minScrollExtent: 0), isTrue);
    });

    test('waits until near the top', () {
      expect(shouldLoadOlder(pixels: 200, minScrollExtent: 0), isFalse);
    });
  });

  group('preservedOffsetAfterInsert', () {
    test('shifts by exactly the inserted extent', () {
      expect(
        preservedOffsetAfterInsert(
          previousPixels: 300,
          addedExtent: 500,
          minScrollExtent: 0,
          maxScrollExtent: 2000,
        ),
        800,
      );
    });

    test('clamps to the scroll range', () {
      expect(
        preservedOffsetAfterInsert(
          previousPixels: 1900,
          addedExtent: 500,
          minScrollExtent: 0,
          maxScrollExtent: 2000,
        ),
        2000,
      );
      expect(
        preservedOffsetAfterInsert(
          previousPixels: 0,
          addedExtent: -500,
          minScrollExtent: 0,
          maxScrollExtent: 2000,
        ),
        0,
      );
    });
  });
}
