import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/widgets/motion.dart';

void main() {
  Widget host(Widget child, {bool reduceMotion = false}) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(body: Center(child: child)),
    ),
  );

  testWidgets('numbers count up to their value, then to new values', (
    tester,
  ) async {
    await tester.pumpWidget(host(const AnimatedValueText('120')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('120'), findsNothing, reason: 'still counting');
    await tester.pumpAndSettle();
    expect(find.text('120'), findsOneWidget);

    await tester.pumpWidget(host(const AnimatedValueText('26.3')));
    await tester.pumpAndSettle();
    expect(find.text('26.3'), findsOneWidget);

    // Words just fade in.
    await tester.pumpWidget(host(const AnimatedValueText('Tuesday')));
    await tester.pumpAndSettle();
    expect(find.text('Tuesday'), findsOneWidget);
  });

  testWidgets('reduced motion shows final values at once', (tester) async {
    await tester.pumpWidget(
      host(const AnimatedValueText('120'), reduceMotion: true),
    );
    expect(find.text('120'), findsOneWidget);

    await tester.pumpWidget(
      host(
        const GrowIn(child: SizedBox(width: 10, height: 50)),
        reduceMotion: true,
      ),
    );
    expect(
      find.descendant(
        of: find.byType(GrowIn),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );
  });

  testWidgets('the live dot rings once per new update, then rests', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const LiveDot(color: Colors.green, pingKey: 1)),
    );
    await tester.pumpWidget(
      host(const LiveDot(color: Colors.green, pingKey: 2)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    // A finite animation: the app settles (no endless pulsing).
    await tester.pumpAndSettle();
  });
}
