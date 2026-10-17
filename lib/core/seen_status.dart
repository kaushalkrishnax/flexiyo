/// Relative label for a read receipt, e.g. "Seen just now" / "Seen 12m ago".
///
/// Falls back to plain "Seen" when the timestamp is unknown or older than a
/// year, where a relative age stops being useful.
String seenStatusLabel(DateTime? seenAt) {
  if (seenAt == null) return 'Seen';
  final elapsed = DateTime.now().difference(seenAt);
  if (elapsed.isNegative || elapsed.inSeconds < 1) return 'Seen just now';
  if (elapsed.inMinutes < 1) return 'Seen ${elapsed.inSeconds}s ago';
  if (elapsed.inHours < 1) return 'Seen ${elapsed.inMinutes}m ago';
  if (elapsed.inDays < 1) return 'Seen ${elapsed.inHours}h ago';
  if (elapsed.inDays < 365) return 'Seen ${elapsed.inDays}d ago';
  return 'Seen';
}
