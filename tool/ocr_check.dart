// CI check that Windows' built-in text reader works with the app's code:
//   dart run tool/ocr_check.dart test/fixtures/mpesa_sample.png
// Reads a batch (the sample twice, plus a missing file) the way dropping
// several photos does, and fails unless the sample payment is found in both
// and the missing file is reported without stopping the others.
import 'dart:io';

import 'package:client_tracker/services/payment_text_parser.dart';
import 'package:client_tracker/services/windows_ocr.dart';

Future<void> main(List<String> args) async {
  final sample = args.single;
  final results = await readTextsOnWindows([
    sample,
    'does-not-exist.png',
    sample,
  ], onProgress: (done) => stdout.writeln('read $done of 3'));
  var ok = true;
  for (final (i, r) in results.indexed) {
    stdout.writeln('--- photo ${i + 1}: ${r.path} ---');
    if (r.error != null) {
      stdout.writeln('error: ${r.error}');
      continue;
    }
    stdout.writeln(r.text);
    final found = parsePayments(r.text ?? '');
    stdout.writeln('payments: ${found.map((p) => p.amountCents)}');
    ok &= found.length == 1 && found.single.amountCents == 4574000;
  }
  ok &= results[0].error == null && results[2].error == null;
  ok &= results[1].error != null;
  if (!ok) {
    stderr.writeln('Expected Ksh45,740.00 in photos 1 and 3, an error for 2');
    exit(1);
  }
  stdout.writeln('OK');
}
