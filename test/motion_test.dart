import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/widgets/motion.dart';

/// Changing page fades the old one out. It must keep the old page as it is
/// while it fades: version 1.3.0 threw it away and built it again from
/// scratch (with every editor on the weekly tracker), which made every
/// page change slow.
void main() {
  testWidgets('the page that is leaving is not built again', (tester) async {
    final starts = <String, int>{};
    Widget page(String name) =>
        KeyedSubtree(key: ValueKey(name), child: _Page(name, starts));
    Widget app(String name) =>
        MaterialApp(home: FadeThroughSwitcher(child: page(name)));

    await tester.pumpWidget(app('tracker'));
    expect(starts, {'tracker': 1});

    await tester.pumpWidget(app('revenue'));
    await tester.pump(const Duration(milliseconds: 50));
    // Both are on screen mid-change; the tracker is the same one as before.
    expect(find.text('tracker'), findsOneWidget);
    expect(find.text('revenue'), findsOneWidget);
    expect(starts, {'tracker': 1, 'revenue': 1});

    await tester.pumpAndSettle();
    expect(find.text('tracker'), findsNothing);
    expect(starts, {'tracker': 1, 'revenue': 1});
  });

  testWidgets('only the new page takes clicks', (tester) async {
    var oldTaps = 0;
    var newTaps = 0;
    Widget app(bool second) => MaterialApp(
      home: FadeThroughSwitcher(
        child: KeyedSubtree(
          key: ValueKey(second),
          child: SizedBox.expand(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => second ? newTaps++ : oldTaps++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(false));
    await tester.pumpWidget(app(true));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(100, 100));
    expect(oldTaps, 0);
    expect(newTaps, 1);
  });
}

class _Page extends StatefulWidget {
  const _Page(this.name, this.starts);
  final String name;
  final Map<String, int> starts;
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  @override
  void initState() {
    super.initState();
    widget.starts.update(widget.name, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) => Text(widget.name);
}
