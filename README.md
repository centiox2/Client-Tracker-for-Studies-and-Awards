# S&A Hub

*Formerly Client Tracker.* The operations app of Studies and Awards Limited: client numbers, revenue, applications, and everyone's daily reports.

A cross-platform **weekly client tracking** app built with **Flutter** — designed to replace the weekly Excel spreadsheet used to record how many **New** and **Existing** clients each staff member handles per day.

Initially targets **Windows desktop**; the same codebase compiles for **Android and iOS** (both platforms are already configured) with a responsive UI (sidebar on desktop, bottom navigation + one-day-at-a-time view on phones).

---

## The workflow it replaces

Instead of rebuilding a spreadsheet every week:

1. Open the app → **New Week**.
2. The app computes the Monday–Friday dates and shows them for confirmation.
3. All **currently active staff** are added to all five days automatically.
4. Enter numbers during the day — **totals update instantly**, everything **saves automatically**.
5. Past weeks stay in **History**, still editable, still exportable.

Values are **cumulative per day**: if Joy has `New = 3` at 10 AM and you type `5` at 1 PM, the stored value is **5** (the current tally), not 8.

## Main screens

| Screen | What it does |
| --- | --- |
| **Dashboard** | Today's totals, this week's New / Existing / Total / Daily Average, staff count, quick actions (Open this week, New week), a by-day stacked bar chart and "Go to" shortcuts. |
| **Weekly Tracker** | Desktop: entire Monday–Friday grid at once (staff rows × day columns of New/Existing, weekly summary per staff). Mobile: one day at a time with a segmented day switcher. Enter moves to the next field. |
| **History** | All weeks with their totals, search, tap to reopen (editable), delete with confirmation. |
| **Staff Management** | Add, rename, deactivate, reactivate, delete (with confirmation), reorder by dragging. Deactivated staff keep all historical numbers and are excluded from new weeks only. |
| **Settings** | Light/Dark/System theme, **Export week → .xlsx**, **Backup / Restore** (portable JSON). |

## Design system — "Editorial"

The UI follows an **Editorial** direction: a warm, print-inspired look (think a well-set newspaper or annual report) for a daily-use data-entry tool. All tokens live in one file — `lib/design/app_theme.dart` — which both screens and widgets import; no screen hardcodes colors or spacing. Shared editorial building blocks (page scaffolds, headers, stat strips, mini bar charts, chips, leaderboard/mix rows) live in `lib/widgets/editorial.dart`.

- **Type pairing**: *Instrument Serif* for display text and every meaningful figure (tabular figures keep columns aligned via `Dt.display` / `Dt.numeral`), *Instrument Sans* for all UI text. Both are bundled in `assets/fonts/` and registered in `pubspec.yaml`.
- **Uppercase micro-labels**: 12px / w600 with +1.1 tracking (`microLabel`) name every section — "THIS WEEK", "DAY TOTAL", "MOST CLIENTS" — like print captions.
- **Duotone data pair, nothing else colored**: New clients are always **peach** (`Dt.newGreen`), Existing clients always **periwinkle** (`Dt.existingBlue`), in inputs, charts and figures alike. Everything else stays in the warm neutral palette; a soft green dot marks Active staff.
- **Warm paper palette**: dark = ink on warm charcoal (`#141211` bg, `#1B1817` panels); light = warm paper (`#F7F4F1` bg, `#EFEAE5` panels). Depth is 1px hairline borders (`Dt.border` / `Dt.borderStrong`); no shadows or gradients.
- **Headlines with an italic accent**: each screen header is a serif headline where one word is set in peach italic ("Thursday, *1 October*", "The week of *October 5*", "The *team*", "Past *weeks*") above a small uppercase kicker.
- **Layout rhythm**: 76px icon rail (serif "C" masthead, Settings pinned bottom) with a 1240px content column (`Dt.contentMaxWidth`); analytics as a 340px right rail that stacks on narrow screens. Radii are small and precise (6/8/12 + stadium pills for buttons).
- **Primary action is an inverse pill** (surface fg on inverse surface) — quiet on purpose; color is reserved for data.

To change the look, edit the tokens in `buildAppTheme` / `Dt` — every screen follows automatically.

## Signing in: personal accounts

When the app is built with the online database (Supabase), everyone signs in
with **their own username and password**:

- **Username** comes from the person's name (`Mary Wanjiku` → `mary.wanjiku`); the admin can change it.
- **Remember me** keeps the person signed in on that device for 30 days of not using the app. Unticked, they are signed out when the app closes — use that on shared computers.
- **Only an admin** creates accounts, gives roles (Admin, Admin team, Director, Team) and resets forgotten passwords, in **Settings › Users**. A new account (or a reset) gets a temporary password; the person chooses their own at their next sign-in.
- **Switch off** an account when someone leaves: they can't sign in, and everything they entered stays.
- **Delete** an account (Settings › Users › ⋮ › Delete account…) to remove it for good. Someone with daily reports can only be deleted together with their reports, so the app offers *Switch off instead*. Nobody can delete their own account or the last admin.
- The sign-in screen remembers the last **username** used on the device (never the password) and warns when **Caps Lock** is on.
- Passwords are stored **only in Supabase, as bcrypt hashes**, in a schema the app's public key can't read. Five wrong passwords in a row lock that account for 15 minutes.
- Without internet, a person can still sign in on a device where they signed in before; the app signs them in online once the connection is back.

### Turning it on (once)

1. In Supabase › SQL Editor, run `supabase/migrations/20261109090000_user_accounts.sql`. The existing admin password becomes the account **`admin`** (same password). Old app versions keep working with the shared profiles.
2. Install the new app on every device. Sign in as `admin`, then add everyone in **Settings › Users**.
3. Once **every** device has the new app, run `supabase/migrations/20261109190000_user_accounts_step2.sql`. It switches the old shared profiles off for good.

Builds without the online database keep the four shared profiles on the device.

## Daily reports (Operations Management, phase 1)

From the Operations Management requirements brief: everyone records the work
they did each day, and management sees it without chasing WhatsApp, email or
spreadsheet updates. On the **Daily reports** page:

- **My reports** — *Add activity*: what was done, the department's measurable outputs (e.g. Applications submitted, COEs issued, Visa lodgements), status (Completed, In progress, Pending, Blocked, Escalated), priority, next action, challenge / blocker, an optional reference, and a due / follow-up date (needed for anything not completed). The person, department and time are recorded automatically. Open items stay listed until done (*Mark done*). Entries can be added up to 7 days back.
- **Overview** (department heads, the Operations Manager, admins, the director) — Today / This week / This month / any dates, by department and person: totals by status, **submission compliance** (who has and hasn't submitted), department summaries with output totals, **needs attention** (overdue, blocked, escalated), and every entry with filters and search.
- **Export** the current view as **PDF or Excel**: Daily Operations, Weekly Performance, Monthly Operations, Staff Activity, Pending Tasks or Exception / Escalation report, depending on the period and filters. Every figure comes from submitted reports, with the period and filters printed on it.

Who sees what is enforced by the online database on every request:

| Report access (Settings › Users) | Sees |
| --- | --- |
| Employee | Their own reports |
| Department head | Everyone in their department |
| Operations manager | Every department |
| Admin / Director role | Every department |

Admins set up **Settings › Departments** (the seven from the brief to start with; rename, add, switch off, and choose the outputs each one counts) and give each person a department in **Settings › Users**. Every add, change and delete is kept in an audit trail (shown on each entry).

Reports are kept **online only** (not copied to every device), so they need an internet connection. Set up with `supabase/migrations/20261109120000_daily_reports.sql`.

Handy extras: a **dot on Daily reports** when you haven't recorded anything today; **Ctrl+Enter** saves an activity; closing a half-filled activity asks first; **Add again today** repeats recurring work; and **Copy reminder** (Overview › Submission compliance) copies a ready-to-send message for everyone who hasn't submitted today.

Not in phase 1 yet (phase 2 of the brief): assigning tasks, an approval step, reminders and overdue alerts by email, and attachments.

## Data safety

- **SQLite** storage (WAL mode, foreign keys ON) — tables `staff`, `weeks`, `work_days`, `client_counts`.
- **Totals are never stored** — always derived from the raw rows, so they can never drift.
- **Automatic rolling DB backups** — the previous 5 sessions' database files are kept (`client_tracker.db.bak1…bak5`).
- **Automatic JSON backup** at every launch (last 10 kept) in `<Documents>/ClientTracker/auto_backups`.
- Restore writes a **safety copy** of current data (`before_restore_*.json`) before overwriting.
- Duplicate weeks are refused; dates are real `DateTime` objects internally and always shown as **DD/MM/YYYY** — the spreadsheet's day/month swap bug can't happen.
- Deleting staff or weeks always asks for confirmation. Deactivation (the recommended option when someone leaves) keeps all history.

## Excel export

Generates a fresh `.xlsx` from database data in the familiar layout: one section per weekday (`Staff | New | Existing` + Total row), then weekly New/Existing/Combined totals, daily average, and a per-staff weekly summary table.

## Build & run

Requires [Flutter](https://docs.flutter.dev/get-started/install/windows) (stable) with the **Visual Studio "Desktop development with C++" workload** for Windows builds.

```bash
flutter pub get
flutter run -d windows       # run on Windows
flutter build windows        # release .exe in build/windows/x64/runner/Release/
flutter test                 # unit + integration + UI smoke tests
flutter analyze              # static analysis
```

### Installing Flutter on this machine (if not already present)

1. Download the stable Windows zip from https://docs.flutter.dev/get-started/install/windows
2. Extract to `C:\src\flutter` and add `C:\src\flutter\bin` to `PATH`.
3. Install Visual Studio Build Tools with the "Desktop development with C++" workload.
4. `flutter doctor` should show Windows development ready.

### Mobile (later, no code changes needed)

```bash
flutter run -d android   # Android device/emulator
flutter run -d ios       # macOS with Xcode required
```

The layout adapts automatically: ≥900 px wide → icon rail; below → bottom navigation; the tracker switches between full-week board with analytics rail (wide) and one-day cards.

## Project structure

```
lib/
  main.dart                  # bootstrap, DB open, auto-backup
  app.dart                   # MaterialApp, responsive shell (76px icon rail)
  design/app_theme.dart      # design tokens + theme builder (single source of visual truth)
  models/staff.dart          # Staff, Week, WorkDay, ClientCount
  database/database.dart     # sqlite3 layer, schema, backup/restore
  repositories/
    staff_repository.dart
    week_repository.dart
    client_count_repository.dart   # + all derived statistics
  services/
    statistics_service.dart
    export_service.dart      # .xlsx generation
    backup_service.dart      # JSON backup/restore + auto-backups
  state/
    providers.dart           # Riverpod wiring (DB overridable in tests)
    app_state.dart           # app-wide state + AppActions
  screens/
    dashboard/
    weekly_tracker/          # incl. New Week dialog
    history/
    staff_management/
    settings/
  widgets/                   # editorial.dart (shared editorial widgets), NumericField, EmptyState, …
```

## Future-proofing

The schema and repository layer were designed so these can be added later without rewrites: cloud sync / multi-machine (JSON backups are already portable), user & company accounts, monthly/yearly analytics (month totals are implemented and derived from day data), PDF/WhatsApp/email report sharing (export service is decoupled from UI), multiple departments, and extra client categories. None of these are implemented yet by design.
