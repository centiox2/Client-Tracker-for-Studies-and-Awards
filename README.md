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

## Design system — "Clarity"

Calm, light-first and data-focused: white cards on a soft grey page, with the Studies and Awards **navy** (`Dt.brandNavy`, `#001A45`) as the one accent and the logo's **gold** (`Dt.brandGold`, `#FBBA00`) taking its place in dark mode. All tokens live in `lib/design/app_theme.dart` (`Dt` for sizes and fixed colours, `Clarity` for the light and dark palettes); shared building blocks (cards, KPI tiles, pills, meters, page headers) live in `lib/widgets/clarity.dart` and `lib/widgets/app_page_header.dart`. No screen hardcodes colours or spacing.

- **Type**: *Inter* (400–700) for everything, with tabular figures for numbers. Bundled in `assets/fonts/` (SIL Open Font License, `Inter-LICENSE.txt`) and registered in `pubspec.yaml`.
- **Numbers first**: the key figure on a card is the biggest thing on it; labels are small and grey.
- **Data colours mean data**: new clients are always **orange** (`seriesNew`, read through `Dt.newGreen`, a name kept from the first design) and existing clients always **blue** (`seriesExisting`, `Dt.existingBlue`), never used as decoration.
- **Status is spelled out**: a coloured status always has a word too (`StatusPill`). No coloured strips on card edges.
- **Quiet chrome**: 1px borders, no shadows, no gradients; radii 8 (buttons, inputs), 12 (cards, dialogs) and pills.
- **Layout**: a 248px sidebar with the S&A logo on desktop (collapsible), a bottom bar on phones; content up to 1680px wide (`Dt.contentMaxWidth`).

To change the look, edit the tokens in `buildAppTheme` / `Dt` — every screen follows automatically.

On phones and tablets, **Settings › You › Mobile and tablet navigation** lets
each person choose up to four pages for the bottom bar, reorder them, and restore
the default order. Other pages remain in **More**. Choices are stored for that
account on the device and only include pages the person may access.

The responsive review covers all main pages and major subviews, including
larger text and short landscape screens. To recreate its review screenshots:

```powershell
$env:UI_REVIEW_CAPTURE = '1'
flutter test test/responsive_ui_test.dart --update-goldens
```

Screenshots are written to `tool/shots/review/` (ignored by Git). Normal
`flutter test` runs the same layout checks without generating images.

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

For the team: department heads and the Operations Manager can **Assign task** (Overview) to anyone they can see, with a due date; it lands in that person's *My open items* marked *Assigned by …*, they update it like their own work, and whoever assigned it can still change it. Anyone who can see an entry can **comment** on it (questions, clarification, feedback). Open items are sorted by due date with *Due today* / *Overdue* labels, and their status changes in one tap. The editor has one-tap due dates (Today, Tomorrow, Friday, Next Monday), and **My week** shows your own days reported, entries, completed and output totals.

Handy extras: a **dot on Daily reports** when you haven't recorded anything today; **Ctrl+Enter** saves an activity; closing a half-filled activity asks first; **Add again today** repeats recurring work; and **Copy reminder** (Overview › Submission compliance) copies a ready-to-send message for everyone who hasn't submitted today.

Since added: assigning tasks, a review step (submitted work is approved or returned with a comment, then resubmitted), in-app notifications, and the To-do page, whose items can be sent to Daily reports. Not built yet: reminders and overdue alerts by email, and attachments.

## Signed builds

### Error-log database update

For an existing online database, apply
`supabase/migrations/20261118073655_error_clear_filter.sql` in the Supabase SQL
Editor. It fixes **Settings › About › Problems reported › Clear** failing with
“DELETE requires a WHERE clause”. Applying it only replaces the function and
does not clear any reports. The server fix also works for existing app versions;
installing a new app alone does not update the online function.

Both apps are signed by GitHub Actions as they're built; the keys live only in the repository's secrets (Settings › Secrets and variables › Actions), never in the code.

Manual Windows and Android builds on a working branch publish separate GitHub
prereleases with downloadable installers/APKs. They do not replace the production
`installer-latest` or `android-latest` releases.

- **Android** — every APK is signed with the company's release key, so each new one installs over the last. Secrets: `ANDROID_KEYSTORE_BASE64` (the `.jks` file, base64), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Without them the Android build stops (it won't publish an APK that can't update the installed one). **Keep a safe copy of the `.jks` file and its password**: a lost key means phones must uninstall and reinstall to get updates.
- **Windows** — the app, installer and uninstaller are signed (Authenticode, SHA-256, timestamped) when `WINDOWS_CERT_PFX_BASE64` (a code-signing certificate `.pfx`, base64) and `WINDOWS_CERT_PASSWORD` are set; without them the installer is built unsigned with a warning. The certificate comes from a certificate authority (an OV or EV code-signing certificate for Studies and Awards Limited).

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


## Daily AI summaries

Admin configures **Settings → Team → AI daily summary**: enter a Gemini API key,
choose the accounts allowed to see company-wide summaries, then save. Enable the
switch if you want the daily schedule.
Keys are masked on entry, stored in Supabase Vault and never returned to the app.
An assigned account can see the whole summary, including revenue, independently
of its normal page permissions. Admin always has access. Personal to-do items,
student/staff names, descriptions and payment notes are excluded from Gemini input.

The Overview card links to **AI summary**, which keeps the latest 30 successful
daily summaries, per-page detail and the recorded aggregate facts used. Dates and
cutoff times use Africa/Nairobi. It runs server-side at **17:05**, even with the app
closed; unsuccessful days retry at 17:15 and 17:25 (maximum three scheduled attempts). Completed
days are never regenerated by scheduled retries. Expired or superseded workers cannot publish.

Admin can press **Generate report now** on Overview or AI summary at any time,
including before 5 pm and with the schedule switched off. A Gemini key must be saved
first. The button shows progress and the report refreshes automatically. Duplicate
requests share the active job. A successful manual run replaces today's displayed
report with a fresh snapshot; failed refreshes leave the last successful report
visible. Manual generation does not cancel the evening scheduled run. Assigned
readers can view reports; only Admin can request generation.

For an existing database, apply `supabase/migrations/20261118080640_daily_ai_summary.sql`
and the follow-ups `20261118082030_ai_summary_job_auth_guard.sql` and
`20261118110032_manual_ai_summary.sql` and `20261118113801_ai_report_failure_messages.sql` and `20261118114826_report_readable_details.sql`, then deploy `supabase/functions/daily-ai-summary` with JWT verification disabled:
the function authenticates its private job token itself, with the claim/finish RPCs
restricted to `service_role`. The migration creates pg_net and uses existing
pg_cron/Vault. It starts **disabled**, with no Gemini key or non-admin assignments.
The dispatch URL in the migration targets this repository's Supabase project;
change it when provisioning a different project. New installations may use the
updated `supabase/schema.sql`. Do not apply both copies of the same schema addition.

The worker follows Google's [structured output REST contract](https://aistudio.google.com/docs/structured-output?generate-content=true).
The model is configurable; verify its availability for your key before enabling.
Gemini is called only when Admin requests a report with a saved key, or enables
the schedule. Generated text is
labelled as AI and should be checked against its recorded facts.

Validation:

```sh
flutter analyze
flutter test
npx deno check supabase/functions/daily-ai-summary/index.ts
npx deno test supabase/functions/daily-ai-summary/
npx deno run --node-modules-dir=none --no-lock -A tool/ai_summary_sql_test.mjs
npx deno run --node-modules-dir=none --no-lock -A tool/manual_ai_summary_sql_test.mjs
```

The SQL suite uses an isolated PGlite database, simulated clock and Vault/network
stubs; it never contacts the production database or Gemini. It exercises access,
secret isolation, aggregates, scheduling gates, concurrency and retry limits.
The live database's RPC-based account system intentionally exposes token-checking
SECURITY DEFINER entry points to anon/authenticated, while private tables have no
client policies. Supabase's corresponding advisor notices are expected for this
architecture; worker claim and persistence RPCs are service-role-only. The manual
request RPC validates the signed-in Admin token before queuing any work.

Overview retains its client KPIs, daily chart/table and client-mix graph, plus revenue, applications, AI summary, one staff count and one card with the current user’s open personal and shared team to-do items. It omits separate History, Reports, Settings and staff-performance summaries.

AI reports now default to `gemini-3.5-flash-lite`, verified with this project’s key. Temporary provider overload/network failures receive at most three attempts with bounded backoff within an 85-second generation budget. Authentication, model-access and quota failures fail promptly with safe, actionable messages. Raw provider bodies and credentials are never included in app errors.

The AI report page uses one document panel with **Summary** and **Detailed report** views. Summary includes a short executive brief, recorded key figures, highlights, attention points and suggested actions. Detailed report adds human-readable figures and status breakdowns, with findings and suggested follow-up for each business area. Money is passed to Gemini in currency units while the recorded snapshot retains cents for exact display. Older reports without detailed findings still open normally.
