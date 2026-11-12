import 'package:flexiyo/widgets/conversation/avatar.dart';
import 'package:flexiyo/widgets/conversation/new_messages_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester tester, {
  required int count,
  required VoidCallback onTap,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: NewMessagesIndicator(
            username: 'aadha',
            count: count,
            onTap: onTap,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders the sender avatar above the drop point', (tester) async {
    await _pump(tester, count: 1, onTap: () {});

    expect(find.byType(UserAvatar), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('1'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is PhysicalShape && widget.clipper is NewMessagesDropClipper,
      ),
      findsOneWidget,
    );
  });

  testWidgets('shows a count badge for multiple unseen messages', (tester) async {
    await _pump(tester, count: 4, onTap: () {});

    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('caps the badge at 9+', (tester) async {
    await _pump(tester, count: 12, onTap: () {});

    expect(find.text('9+'), findsOneWidget);
  });

  testWidgets('tapping jumps to the latest message', (tester) async {
    var taps = 0;
    await _pump(tester, count: 2, onTap: () => taps += 1);

    await tester.tap(find.byType(NewMessagesIndicator));
    await tester.pump();

    expect(taps, 1);
  });

  testWidgets('exposes a button label for screen readers', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, count: 3, onTap: () {});

    expect(
      find.bySemanticsLabel(RegExp('Jump to latest')),
      findsOneWidget,
    );
    handle.dispose();
  });

  test('the drop clip stays within the widget bounds', () {
    final path = const NewMessagesDropClipper().getClip(const Size(64, 70));
    final bounds = path.getBounds();

    expect(bounds.left, greaterThanOrEqualTo(0));
    expect(bounds.top, greaterThanOrEqualTo(0));
    expect(bounds.right, lessThanOrEqualTo(64));
    expect(bounds.bottom, lessThanOrEqualTo(70));
  });
}
