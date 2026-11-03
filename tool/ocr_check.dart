// CI check that Windows' built-in text reader works with the app's code:
//   dart run tool/ocr_check.dart test/fixtures/mpesa_sample.png
// Prints the text read and fails unless the sample payment is found.
import 'dart:io';

import 'package:client_tracker/services/payment_text_parser.dart';
import 'package:client_tracker/services/windows_ocr.dart';

Future<void> main(List<String> args) async {
  final text = await readTextOnWindows(args.single);
  stdout.writeln('--- text read ---\n$text\n-----------------');
  final found = parsePayments(text);
  stdout.writeln('Payments found: ${found.map((p) => p.amountCents)}');
  if (found.length != 1 || found.single.amountCents != 4574000) {
    stderr.writeln('Expected one payment of Ksh45,740.00');
    exit(1);
  }
}
