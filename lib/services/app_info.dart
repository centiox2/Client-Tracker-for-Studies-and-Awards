import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// The app's version and what changed in each release. [version] must match
/// pubspec.yaml (a test checks), so Settings, the "What's new" window and
/// the installers all say the same.
abstract final class AppInfo {
  static const version = '1.7.0';

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
    Release('1.7.0', 'November 2026', [
      'New To-do page for everyone: a personal list for your day. It is '
          'saved with your account, so it is the same on all your devices, '
          'and it still works offline. Send items to Daily reports when you '
          'want them there: done ones go for review, the rest go on your '
          'list.',
      'Daily reports: a task is either Done or To do, picked with two '
          'buttons instead of a drop-down.',
      'Search in Daily reports is a button until you need it (or press /).',
      'Resubmitting returned work: what you sent before is filled in, and '
          'you can change any of it (the title too, for your own tasks).',
      'Returned work no longer counts as submitted in Team figures until '
          'it is resubmitted.',
      'Review updates by itself when your team submits work; no need to '
          'switch tabs.',
      'Tidier task cards and phone layouts, with less repeated text.',
    ]),
    Release('1.6.0', 'November 2026', [
      'Daily reports: My tasks opens with Today’s list. Type each thing '
          'you did or plan to do and press Enter; it waits on the list '
          'until you submit, so you can add several and check them first.',
      'Each item’s status is a drop-down (Done today, Doing now or To do), '
          'with its urgency and due day beside it. Done items go for review '
          'with their counts; the rest go on your list. One button saves '
          'them all, with Undo.',
      'Today’s list is kept on this device until you submit it, even if '
          'you close the app.',
      'Add with details has a Status drop-down instead of three buttons.',
      'A "Submitted today" section shows what you have sent today and how '
          'many are approved.',
    ]),
    Release('1.5.0', 'November 2026', [
      'Daily reports, quicker: tick a task to submit it. The submit window '
          'only opens when your department records counts, or with '
          '"Submit with details".',
      'The quick line understands what you type: "Lodged visas 3 done" '
          'submits finished work with its count; "Call embassy tomorrow '
          'urgent" sets the due day and urgency. It shows what it '
          'understood before you press Enter.',
      'Paste a list into the quick line: each line becomes a task.',
      'No internet? What you add or submit is kept on this device, marked '
          '"Waiting to send", and sent when you are back online, for the '
          'day you did it.',
      'Add activity is shorter: urgency, due date, notes and the reference '
          'are under "More details". It remembers whether you last chose '
          'Done today or To do, and the urgency.',
      'No more "Are you sure?": deleting, closing without saving, changing '
          'the status and submitting all offer Undo instead.',
      'Wrap up my day: tick everything you finished and submit it '
          'together.',
      'The reference box suggests student names from Applications.',
      'Tapping a notification opens its task at once; the 4 pm reminder '
          'opens the quick line, ready to type.',
      'Keys: N for the quick line, / to search, Enter adds, Ctrl+Enter adds '
          'it as done, Esc leaves the box, the arrow keys move between tasks '
          'and Space ticks one.',
      'The separate Start button is gone: use the status label.',
    ]),
    Release('1.4.0', 'November 2026', [
      'Daily reports rebuilt around tasks. Tabs: My tasks, My submissions, '
          'Review (for whoever reviews work) and Team.',
      'My tasks: a to-do list. Add what you are going to do or are doing, '
          'set Doing or Blocked in one tap, and Submit each task when it is '
          'done. Managers see the status.',
      'Add activity: choose Done today, Doing now or To do; set urgency, a '
          'due date in one tap, counts with − and + buttons, and use '
          '"Save & add another" for several in a row.',
      'Directors, managers and department heads assign tasks to anyone, to '
          'several people at once, with a colour for urgency: grey Low, blue '
          'Normal, orange High, red Urgent.',
      'Review: approve submitted work, or return it with a comment. The '
          'person sees why, fixes it and resubmits; the timeline keeps every '
          'step and comment.',
      'Every task has a number (#123), and the day and time it was '
          'submitted is filled in automatically.',
      'Search tasks by words, a person, a department or #number, from the '
          'box at the top. On phones and tablets search is in the top bar.',
      'Notifications (the bell): new tasks, returned or approved work, '
          'comments, blocked tasks, things due today or overdue, and a 4 pm '
          'reminder if you have not submitted anything.',
      'Daily reports opens straight away: what you saw last is kept on '
          'this device and updated in the background.',
      'Older versions of the app can no longer use Daily reports. Install '
          'this version on every computer and phone.',
    ]),
    Release('1.3.2', 'November 2026', [
      'Applications: "Needs attention" is now "No change in 14+ days". Any '
          'change in Airtable counts as work (status, notes, follow-up, '
          'assignee), and dates anywhere in the notes count too. Each one '
          'says what was last done and when.',
      'Reports › Quick view: every card can be moved (press and hold).',
      'Reports on a phone: the tabs no longer jump when switching.',
    ]),
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
