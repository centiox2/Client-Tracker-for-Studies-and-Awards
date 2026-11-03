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

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$max = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
$paths = $env:CT_OCR_IMAGES -split "`n"
for ($i = 0; $i -lt $paths.Count; $i++) {
  $path = $paths[$i].Trim()
  if ($path -eq '') { continue }
  try {
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    # Windows' reader has a size limit; shrink big phone photos to fit.
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
    [Console]::Out.WriteLine("===CT_FILE:$($i)===")
    foreach ($line in $result.Lines) { [Console]::Out.WriteLine($line.Text) }
  } catch {
    # One unreadable photo mustn't stop the others.
    $e = $_.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    $msg = ($e.Message -replace "[\r\n]+", ' ')
    [Console]::Out.WriteLine("===CT_ERROR:$($i):$($msg)===")
  }
  [Console]::Out.Flush()
}
} catch {
  # Report the real reason as plain text (PowerShell would otherwise wrap
  # it in CLIXML on stderr).
  $e = $_.Exception
  while ($e.InnerException) { $e = $e.InnerException }
  [Console]::Out.WriteLine('OCR_ERROR: ' + $e.Message)
  exit 4
}
''';

/// The text read from one photo, or why it couldn't be read.
class WindowsOcrResult {
  const WindowsOcrResult(this.path, {this.text, this.error});
  final String path;
  final String? text;
  final String? error;
}

/// Reads the text in the image at [path], one line per text line.
Future<String> readTextOnWindows(String path) async {
  final r = (await readTextsOnWindows([path])).single;
  if (r.error != null) {
    throw WindowsOcrException('Windows couldn’t read that image (${r.error}).');
  }
  return r.text ?? '';
}

/// Reads many images in one go (Windows' reader starts once, which is much
/// quicker than once per photo). [onProgress] gets the number done so far.
/// A photo that can't be read gets an [WindowsOcrResult.error]; the rest
/// carry on.
Future<List<WindowsOcrResult>> readTextsOnWindows(
  List<String> paths, {
  void Function(int done)? onProgress,
}) async {
  if (paths.isEmpty) return const [];
  // -EncodedCommand takes UTF-16LE base64: no quoting problems at all.
  final units = _script.codeUnits;
  final bytes = <int>[
    for (final u in units) ...[u & 0xff, u >> 8],
  ];
  final Process process;
  try {
    process = await Process.start(
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
      // Paths go in an environment variable, one per line, never into the
      // script. Windows' file API rejects paths that mix / and \\.
      environment: {
        'CT_OCR_IMAGES': [
          for (final p in paths) File(p).absolute.path.replaceAll('/', r'\'),
        ].join('\n'),
      },
    );
  } on ProcessException {
    throw WindowsOcrException(
      'Windows PowerShell isn’t available on this PC, so photos can’t be '
      'read here. Use Paste message instead.',
    );
  }

  final texts = <int, StringBuffer>{};
  final errors = <int, String>{};
  final general = StringBuffer();
  int? current;
  var done = 0;
  final fileMark = RegExp(r'^===CT_FILE:(\d+)===$');
  final errorMark = RegExp(r'^===CT_ERROR:(\d+):(.*)===$');
  final stderrText = process.stderr.transform(utf8.decoder).join();
  await for (final line
      in process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 120))) {
    final f = fileMark.firstMatch(line);
    final e = errorMark.firstMatch(line);
    if (f != null) {
      current = int.parse(f.group(1)!);
      texts[current] = StringBuffer();
      onProgress?.call(++done);
    } else if (e != null) {
      current = null;
      errors[int.parse(e.group(1)!)] = e.group(2)!.trim();
      onProgress?.call(++done);
    } else if (current != null) {
      texts[current]!.writeln(line);
    } else {
      general.writeln(line);
    }
  }
  final exitCode = await process.exitCode;
  final err = await stderrText;
  if (exitCode == 3 || err.contains('NO_OCR_LANGUAGE')) {
    throw WindowsOcrException(
      'Windows has no text-reading language installed. Add English in '
      'Settings › Time & language › Language & region, then try again.',
    );
  }
  if (exitCode != 0) {
    final reported = RegExp(r'OCR_ERROR: (.*)')
        .firstMatch(general.toString())
        ?.group(1);
    final detail = (reported ?? err).trim().split('\n').first;
    throw WindowsOcrException(
      'Windows couldn’t read photos'
      '${detail.isEmpty ? '' : ' ($detail)'}.',
    );
  }
  return [
    for (var i = 0; i < paths.length; i++)
      WindowsOcrResult(
        paths[i],
        text: texts[i]?.toString().trim(),
        error: texts.containsKey(i)
            ? null
            : errors[i] ?? 'nothing was returned for this photo',
      ),
  ];
}
