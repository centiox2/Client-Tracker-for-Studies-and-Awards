// Sign-in and profile screens, using real fonts for visual review.
// flutter test tool/auth_review_test.dart --update-goldens
import 'dart:io';

import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/design/app_theme.dart';
import 'package:client_tracker/screens/auth/login_screen.dart';
import 'package:client_tracker/screens/auth/profile_picker.dart';
import 'package:client_tracker/screens/auth/sign_in_screen.dart';
import 'package:client_tracker/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    final font = FontLoader('Inter');
    for (final weight in [400, 500, 600, 700]) {
      font.addFont(rootBundle.load('assets/fonts/Inter-$weight.ttf'));
    }
    await font.load();
    final root = Platform.environment['FLUTTER_ROOT']!;
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            File(
              '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytesSync(),
          ),
        ),
      );
    await icons.load();
  });
  for (final (mode, size) in [
    ('desktop', const Size(1440, 1000)),
    ('phone', const Size(390, 844)),
    ('landscape', const Size(740, 390)),
  ]) {
    for (final (name, page) in <(String, Widget)>[
      ('profiles', const ProfilePickerScreen()),
      ('login', const LoginScreen()),
      ('setup', const SignInScreen()),
    ]) {
      testWidgets('$name $mode', (tester) async {
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.setMockInitialValues({});
        final db = openInMemoryDatabase();
        addTearDown(db.close);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [databaseProvider.overrideWithValue(db)],
            child: MaterialApp(
              theme: buildAppTheme(Brightness.light),
              home: page,
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 11));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('shots/review/$mode-$name.png'),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }
}
