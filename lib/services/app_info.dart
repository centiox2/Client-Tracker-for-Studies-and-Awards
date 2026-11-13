import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// The app's version and what changed in each release. [version] must match
/// pubspec.yaml (a test checks), so Settings, the "What's new" window and
/// the installers all say the same.
abstract final class AppInfo {
  static const version = '1.3.1';

  /// Show "What's new" after an update (the real app only; tests leave it
  /// off so it never covers the screen under test).
  static bool showWhatsNew = false;

  /// "Windows PC · OFFICE-PC": the kind of device and its name, so people
  /// can tell their sessions apart.
  static String get device {
    final kind = kIsWeb
        ? 'Web browser'
        : switch (defaultTargetPlatform) {
            TargetPlatform.windows => 'Windows PC',
            TargetPlatform.android => 'Android phone',
            TargetPlatform.iOS => 'iPhone',
            TargetPlatform.macOS => 'Mac',
            TargetPlatform.linux => 'Linux PC',
            TargetPlatform.fuchsia => 'Device',
          };
    if (kIsWeb) return kind;
    try {
      final name = Platform.localHostname.trim();
      return name.isEmpty || name == 'localhost' ? kind : '$kind · $name';
    } catch (_) {
      return kind;
    }
  }

  static String get platform => kIsWeb ? 'web' : defaultTargetPlatform.name;

  /// Newest first.
  static const releases = <Release>[
    Release('1.3.1', 'November 2026', [
      'Moving cards: press and hold, then drag. A click just opens the card, '
          'and a lifted card has a white outline.',
      'Revenue charts are green, like money.',
      'Two smaller text sizes (Settings › Text size).',
      'Faster page changes, sidebar and light/dark switching.',
      'Pages arrive more smoothly: figures count up and cards come in one '
          'after another.',
      'Fixed a crash in the weekly tracker when leaving a cell.',
      'Settings › About: copy a reported problem, or all of them, to paste '
          'into a message.',
    ]),
    Release('1.3.0', 'November 2026', [
      'Search everything from any page (Ctrl K or /): clients, staff, weeks '
          'and payments. Commas, full stops and apostrophes don’t matter, '
          'and a client opens straight to their card.',
      'Settings is for everyone, grouped into You, Workspace, Team, Data and '
          'About, and your choices follow you to every device.',
      'Admins choose which pages each account can open, and see which staff '
          'record an account is linked to.',
      'Overview: tap any figure to open its page; the Client mix card is '
          'back; cards can be dragged anywhere.',
      'Weekly tracker: a warning before changing a past week; Change history '
          'covers every week.',
      'Daily reports open in one step and are tidier; today’s reports also '
          'show on Overview and Reports.',
      'Revenue: paste a payment screenshot or message with Ctrl V.',
      'Backups now also save what lives only online (accounts without '
          'their passwords, departments, daily reports). Restoring puts '
          'back any departments and daily reports that are missing.',
      'Smoother page changes, sharper layouts on 1080p screens and phones. '
          'TV mode has been removed.',
    ]),
    Release('1.2.2', 'November 2026', [
      'Phones and tablets: no more text cut short (Airtable sync time, '
          'names, notes, card captions, search hints).',
      'All applications: each group of applications is a whole card again.',
      'Reports › Details: switching Day, Week, Month and Year no longer '
          'moves the buttons beside them.',
      'Reports › Month: the Staff by day table fits (it was a little too '
          'narrow on every screen).',
    ]),
    Release('1.2.1', 'November 2026', [
      'Tidier phone and tablet layouts: the weekly tracker is one clear '
          'table, cards are more compact, filters sit two to a row, and '
          'tables fit without words breaking.',
      'Applications is in the phone bottom bar; Daily reports moved under '
          'More.',
      'Drag the summary cards into any order (press and hold on a phone or '
          'tablet). Reset in Settings › Appearance.',
    ]),
    Release('1.2.0', 'November 2026', [
      'A new look: the Clarity design, in the Studies and Awards colours, '
          'with light and dark modes.',
      'Applications come straight from Airtable, with Sync now.',
      'Offer letter reminders after 7 days, and sorting and filtering in '
          'All applications.',
      'The sidebar can close to a strip of icons.',
      'See where you’re signed in and sign out of other devices '
          '(Settings › Your sessions).',
      'An activity log of who changed what (admins).',
      'Undo after deleting a payment, a week or a staff member.',
      'Text size setting, keyboard shortcuts (press ? to see them), and '
          'printable PDFs of a week, a report and a student.',
      'Clearer empty pages that say what to do next.',
      'Unexpected errors are reported automatically, so they can be fixed '
          'sooner.',
      'Pages remember their last tab and sort.',
      'Show zeros no longer starts a sync.',
    ]),
    Release('1.1.0', 'November 2026', [
      'Personal accounts with Remember me.',
      'Daily reports, assigned tasks, comments and My week.',
      'Signed Windows installer and Android app.',
    ]),
  ];
}

class Release {
  const Release(this.version, this.date, this.items);
  final String version;
  final String date;
  final List<String> items;
}
