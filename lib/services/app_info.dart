import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// The app's version and what changed in each release. [version] must match
/// pubspec.yaml (a test checks), so Settings, the "What's new" window and
/// the installers all say the same.
abstract final class AppInfo {
  static const version = '1.9.0';

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
    Release('1.9.0', 'November 2026', [
      'Overview now shows a concise snapshot and link for each available page.',
      'Company-wide Gemini summaries: an Overview card, a dedicated history and details page, '
          'and Admin controls for the API key and assigned viewers in Settings > Team.',
      'Summaries run after 5 pm Nairobi time, even when the app is closed. '
          'Admin must add a key and enable the schedule first.',
    ]),
    Release('1.8.5', 'November 2026', [
      'Clearing reported problems handles connection or database errors '
          'without losing the displayed reports. Repeated clicks are disabled '
          'while clearing.',
    ]),
    Release('1.8.4', 'November 2026', [
      'Cleaner page headers, aligned card actions and less toolbar clutter.',
      'Improved phone and tablet layouts for Staff, To-do, Daily reports, '
          'Applications and Settings, including larger text and landscape screens.',
      'Choose and reorder up to four bottom-bar pages in Settings › You. '
          'Other pages stay in More; your choices are saved on this device.',
    ]),
    Release('1.8.3', 'November 2026', [
      'Passwords need at least 8 characters, and are stored with stronger '
          'protection (older ones are upgraded the next time you sign in).',
      'Too many wrong admin or profile passwords, or recovery codes, lock '
          'that sign-in for 15 minutes; kept sign-ins end after 90 days.',
      'Sync: one change the online database refuses no longer holds up the '
          'rest. It is set aside in Settings to save, retry or discard.',
      'An account given no pages now really gets none.',
      'Imports: a short CSV row keeps the values it doesn\'t include, two-'
          'digit years are read, and a failed Excel import changes nothing '
          '(with warnings for repeated rows and fractions).',
      'Fixes: the week number around New Year, refund totals in Scan '
          'photo, averages that counted numbers typed ahead, "Offers this '
          'month", and the dashboard\'s week list now opens the week.',
      'Undo, backups and assigning a task to several people are safer when '
          'something goes wrong part-way.',
    ]),
    Release('1.8.2', 'November 2026', [
      'Safer sign-in: a temporary password only lets you set a new one, and '
          'each account only reads and changes the pages it may open.',
      'Sync: offline changes from two devices no longer overwrite newer '
          'ones online, and the same week or day made on two devices is '
          'joined instead of doubled.',
      'Download fresh copy and the first join keep your unsent changes as '
          'a copy you can save (Settings › Backup), instead of losing them.',
      'Daily reports: a task the server refuses stays on your device with '
          'the reason, to fix or discard; a task is never saved twice after '
          'a dropped connection; exports include every matching task.',
      'Approved tasks that are changed go back for review.',
      'Applications upload: a damaged or cut-off file is refused, and you '
          'are asked before many applications are removed.',
      'Backups hold everyone\'s to-do lists, and backup files on this '
          'device no longer keep saved sign-ins.',
      'Team to-dos stay with their team if you move departments; a damaged '
          'to-do no longer stops the list loading.',
      'Excel import: numbers for a day marked off clear the off mark.',
      'Android: saving files works on newer phones, and sharing very large '
          'photos no longer freezes the app.',
    ]),
    Release('1.8.1', 'November 2026', [
      'To-do: what you don\'t finish moves to the next day, under '
          '"Yesterday’s unfinished" at the top, until you bring it to today '
          'or move it to later.',
      'To-do: click the box and the choices show straight away (day, '
          'deadline, repeat, star, notes), so you set them before adding. '
          'More… opens the whole form for a new to-do.',
    ]),
    Release('1.8.0', 'November 2026', [
      'To-do: anything not finished yesterday waits at the top, ready to '
          'bring to today or move to later. Overdue items come first.',
      'To-do: plan items for today, a day, or later, give them a deadline '
          'with a time, star the important ones and drag to reorder.',
      'To-do: type naturally: "Call the embassy tomorrow 3pm !" sets the '
          'day, the deadline and a star for you.',
      'To-do: notes, small steps, counts and a linked client on each item; '
          'repeating items (every day, weekdays, weekly, monthly).',
      'To-do: add one from any page with the new button at the top or the '
          'T key, or from a client’s card ("Add to my to-do").',
      'To-do: select many to tick, move, send or delete together; swipe '
          'right to tick and left to delete on phones; keyboard keys too.',
      'To-do: see where sent items are (awaiting review, approved, '
          'returned) and open the task; items finished in Daily reports '
          'tick themselves.',
      'To-do: a reminder at the end of the day to send what you finished '
          '(choose the time in To-do settings), a progress bar, and a '
          'History of what you got done.',
      'To-do: give an item to a colleague, and share a team list with '
          'your department.',
    ]),
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
