import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/widgets/numeric_field.dart';

/// A tracker cell is given a focus node that lives longer than the cell.
/// Version 1.2.2 kept listening to it after the cell was gone, and the next
/// focus change crashed ("Null check operator used on a null value" in
/// _NumericFieldState._onFocusChanged).
void main() {
  Widget cell(FocusNode node, {Key? key}) => MaterialApp(
    home: Scaffold(
      body: NumericField(
        key: key,
        value: 3,
        onChanged: (_) {},
        focusNode: node,
      ),
    ),
  );

  testWidgets('a focus node handed to a new cell (another week) no longer '
      'calls the old one', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(cell(node, key: const ValueKey('week-1')));
    // The week changes: a new cell, the same (remembered) focus node.
    await tester.pumpWidget(cell(node, key: const ValueKey('week-2')));
    node.requestFocus();
    await tester.pump();
    expect(node.hasFocus, isTrue);
    node.unfocus();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a cell given a new focus node listens to the new one only', (
    tester,
  ) async {
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(cell(first));
    await tester.pumpWidget(cell(second));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    first.requestFocus();
    await tester.pump();
    first.unfocus();
    second.requestFocus();
    await tester.pump();
    second.unfocus();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
