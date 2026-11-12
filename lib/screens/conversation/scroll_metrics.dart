/// Scroll geometry decisions for the conversation timeline.
///
/// Kept pure so the auto-follow and back-fill behaviour can be tested without
/// mounting the whole screen.
library;

/// Distance from the bottom that still counts as "reading the latest".
const double bottomFollowThreshold = 80;

/// Distance from the top that triggers loading an older page.
const double topLoadThreshold = 120;

bool isAtBottom({
  required double pixels,
  required double maxScrollExtent,
  double threshold = bottomFollowThreshold,
}) =>
    pixels >= maxScrollExtent - threshold;

bool shouldLoadOlder({
  required double pixels,
  required double minScrollExtent,
  double threshold = topLoadThreshold,
}) =>
    pixels <= minScrollExtent + threshold;

/// Offset that keeps the previously visible message in place after [addedExtent]
/// was inserted above it.
double preservedOffsetAfterInsert({
  required double previousPixels,
  required double addedExtent,
  required double minScrollExtent,
  required double maxScrollExtent,
}) =>
    (previousPixels + addedExtent)
        .clamp(minScrollExtent, maxScrollExtent)
        .toDouble();
