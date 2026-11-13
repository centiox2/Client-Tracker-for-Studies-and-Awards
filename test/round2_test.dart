import 'package:client_tracker/screens/settings/about_section.dart';
import 'package:client_tracker/services/account_services.dart';
import 'package:client_tracker/widgets/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('figures count up', () {
    test('a figure with one number in it is read with its words', () {
      expect(AnimatedValueText.parse('KSh 12,300'), (
        'KSh ',
        12300,
        0,
        true,
        '',
      ));
      expect(AnimatedValueText.parse('45%'), ('', 45, 0, false, '%'));
      expect(AnimatedValueText.parse('26.3 h'), ('', 26.3, 1, false, ' h'));
      expect(AnimatedValueText.parse('3 of 5'), isNull);
      expect(AnimatedValueText.parse('Tuesday'), isNull);
      expect(AnimatedValueText.parse('09:30'), isNull);
      expect(AnimatedValueText.parse('1,2'), isNull);
    });

    testWidgets('it counts with its commas and ends on the exact text', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: AnimatedValueText('KSh 12,300')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final mid = tester.widget<Text>(find.byType(Text)).data!;
      expect(mid, matches(RegExp(r'^KSh \d{1,3}(,\d{3})*$')));
      expect(mid, isNot('KSh 12,300'));
      await tester.pumpAndSettle();
      expect(find.text('KSh 12,300'), findsOneWidget);
    });
  });

  testWidgets('a reported problem can be copied, one or all', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    Future<Object?> call(String name, [Map<String, Object?>? _]) async =>
        name == 'error_list'
        ? [
            {
              'message': 'Null check operator used on a null value',
              'stack': '#0 _NumericFieldState._onFocusChanged',
              'count': 3,
              'app_version': '1.2.2',
              'platform': 'windows',
            },
            {'message': 'Second problem', 'stack': '#0 elsewhere'},
          ]
        : null;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          errorsServiceProvider.overrideWithValue(ErrorsService(call)),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: AboutSection(online: true)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('copy-problem-0')));
    await tester.pumpAndSettle();
    expect(copied, contains('Null check operator used on a null value'));
    expect(copied, contains('Seen 3×'));
    expect(copied, contains('v1.2.2 · windows'));
    expect(copied, contains('_NumericFieldState._onFocusChanged'));
    expect(copied, isNot(contains('Second problem')));

    await tester.tap(find.byKey(const ValueKey('copy-all-problems')));
    await tester.pumpAndSettle();
    expect(copied, contains('Null check operator'));
    expect(copied, contains('Second problem'));

    // The details open in place, as text that can be selected.
    await tester.tap(find.byKey(const ValueKey('problem-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('problem-details-0')), findsOneWidget);
    expect(find.byType(SelectableText), findsWidgets);
  });
}
