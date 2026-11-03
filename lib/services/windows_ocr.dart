/// Text recognition on Windows, using the reader built into Windows 10/11
/// (Windows.Media.Ocr): offline, free, nothing uploaded, no extra software.
///
/// It's reached through Windows PowerShell 5.1, which ships with every
/// Windows 10/11 PC and can call Windows' own APIs. Plain dart:io only, so
/// a command-line check (tool/ocr_check.dart) can use it too.
library;

import 'dart:convert';
import 'dart:io';

/// Thrown when Windows can't read the photo; [message] is for the user.
class WindowsOcrException implements Exception {
  WindowsOcrException(this.message);
  final String message;
  @override
  String toString() => message;
}

// The image path arrives in an environment variable, never inside the
// script text, so no file name can change what runs.
const _script = r'''
$ErrorActionPreference = 'Stop'
try {
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, [Type]$type) {
  $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
  $task.Wait(-1) | Out-Null
  $task.Result
}
[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
[Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime] | Out-Null

$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if ($null -eq $engine) {
  $en = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]::new('en-US')
  $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($en)
}
if ($null -eq $engine) { [Console]::Error.WriteLine('NO_OCR_LANGUAGE'); exit 3 }

$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($env:CT_OCR_IMAGE)) ([Windows.Storage.StorageFile])
$stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])

# Windows' reader has a size limit; shrink big phone photos to fit.
$max = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
$w = $decoder.PixelWidth; $h = $decoder.PixelHeight
if ($w -gt $max -or $h -gt $max) {
  $scale = [Math]::Min($max / $w, $max / $h)
  $transform = [Windows.Graphics.Imaging.BitmapTransform]::new()
  $transform.ScaledWidth = [uint32][Math]::Floor($w * $scale)
  $transform.ScaledHeight = [uint32][Math]::Floor($h * $scale)
  $transform.InterpolationMode = [Windows.Graphics.Imaging.BitmapInterpolationMode]::Fant
  $bitmap = Await ($decoder.GetSoftwareBitmapAsync(
    [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
    [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied,
    $transform,
    [Windows.Graphics.Imaging.ExifOrientationMode]::RespectExifOrientation,
    [Windows.Graphics.Imaging.ColorManagementMode]::DoNotColorManage)) ([Windows.Graphics.Imaging.SoftwareBitmap])
} else {
  $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
}

$result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
$stream.Dispose()
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
foreach ($line in $result.Lines) { [Console]::Out.WriteLine($line.Text) }
} catch {
  # Report the real reason as plain text (PowerShell would otherwise wrap
  # it in CLIXML on stderr).
  $e = $_.Exception
  while ($e.InnerException) { $e = $e.InnerException }
  [Console]::Out.WriteLine('OCR_ERROR: ' + $e.Message)
  exit 4
}
''';

/// Reads the text in the image at [path], one line per text line.
Future<String> readTextOnWindows(String path) async {
  // -EncodedCommand takes UTF-16LE base64: no quoting problems at all.
  final units = _script.codeUnits;
  final bytes = <int>[
    for (final u in units) ...[u & 0xff, u >> 8],
  ];
  final ProcessResult result;
  try {
    result = await Process.run(
      'powershell.exe',
      [
        // The app has no console of its own; keep PowerShell's hidden.
        '-WindowStyle',
        'Hidden',
        '-NoProfile',
        '-NonInteractive',
        '-OutputFormat',
        'Text',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        base64.encode(bytes),
      ],
      environment: {'CT_OCR_IMAGE': File(path).absolute.path},
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 60));
  } on ProcessException {
    throw WindowsOcrException(
      'Windows PowerShell isn’t available on this PC, so photos can’t be '
      'read here. Use Paste message instead.',
    );
  }
  if (result.exitCode == 3 ||
      (result.stderr as String).contains('NO_OCR_LANGUAGE')) {
    throw WindowsOcrException(
      'Windows has no text-reading language installed. Add English in '
      'Settings › Time & language › Language & region, then try again.',
    );
  }
  final out = (result.stdout as String).trim();
  if (result.exitCode != 0) {
    final reported = RegExp(r'OCR_ERROR: (.*)').firstMatch(out)?.group(1);
    final detail = (reported ?? (result.stderr as String))
        .trim()
        .split('\n')
        .first;
    throw WindowsOcrException(
      'Windows couldn’t read that image'
      '${detail.isEmpty ? '' : ' ($detail)'}.',
    );
  }
  return out;
}
