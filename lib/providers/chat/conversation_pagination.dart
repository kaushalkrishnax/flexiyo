import 'package:flexiyo/models/message.dart';

/// Chronological ordering with a stable id tie-break.
int compareMessages(Message a, Message b) {
  final timestamp = a.createdAt.compareTo(b.createdAt);
  return timestamp != 0 ? timestamp : a.id.compareTo(b.id);
}

/// Merges an older page into the visible list, de-duplicating by id and
/// keeping chronological order. Messages already on screen win, so locally
/// hydrated state (decrypted text, status) is not replaced by a raw row.
List<Message> mergeOlderPage({
  required Iterable<Message> older,
  required List<Message> current,
}) {
  return <String, Message>{
    for (final message in older) message.id: message,
    for (final message in current) message.id: message,
  }.values.toList()
    ..sort(compareMessages);
}

/// A page is considered exhausted only when it returned fewer rows than the
/// requested page size.
bool hasOlderPage({required int fetched, int pageSize = 10}) =>
    fetched >= pageSize;
