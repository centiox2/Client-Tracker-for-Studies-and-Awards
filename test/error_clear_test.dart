import 'dart:async';

import 'package:client_tracker/design/app_theme.dart';
import 'package:client_tracker/screens/settings/about_section.dart';
import 'package:client_tracker/services/account_services.dart';
import 'package:client_tracker/services/cloud/cloud_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'failed clear keeps reports and can be retried at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var attempts = 0;
        var listCalls = 0;
        var cleared = false;
        Future<Object?> call(String name, [Map<String, Object?>? _]) async {
          if (name == 'error_list') {
            listCalls++;
            return cleared
                ? []
                : [
                    {
                      'message': 'Original reported problem',
                      'stack': '#0 original',
                    },
                  ];
          }
          if (name == 'error_clear') {
            attempts++;
            if (attempts == 1) {
              throw CloudException('other', 'DELETE requires a WHERE clause');
            }
            cleared = true;
          }
          return null;
        }

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              errorsServiceProvider.overrideWithValue(ErrorsService(call)),
            ],
            child: MaterialApp(
              theme: buildAppTheme(Brightness.light),
              home: const Scaffold(
                body: SingleChildScrollView(child: AboutSection(online: true)),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final clear = find.byKey(const ValueKey('clear-problems'));
        await tester.ensureVisible(clear);
        await tester.pumpAndSettle();
        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('clear-problems-error')),
          findsOneWidget,
        );
        expect(find.textContaining('error-log update'), findsOneWidget);
        expect(find.byKey(const ValueKey('problem-0')), findsOneWidget);
        expect(
          listCalls,
          1,
          reason: 'Failed clearing must not replace the existing log.',
        );
        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(attempts, 2);
        expect(listCalls, 2);
        expect(
          find.byKey(const ValueKey('clear-problems-error')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('problem-0')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('clearing is disabled while the request is pending', (
    tester,
  ) async {
    final pending = Completer<void>();
    var calls = 0;
    var cleared = false;
    Future<Object?> call(String name, [Map<String, Object?>? _]) async {
      if (name == 'error_list') {
        return cleared
            ? []
            : [
                {'message': 'Test problem'},
              ];
      }
      if (name == 'error_clear') {
        calls++;
        await pending.future;
        cleared = true;
      }
      return null;
    }

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
    final clear = find.byKey(const ValueKey('clear-problems'));
    await tester.tap(clear);
    await tester.pump();
    expect(tester.widget<TextButton>(clear).onPressed, isNull);
    await tester.tap(clear);
    expect(calls, 1);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('problem-0')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
