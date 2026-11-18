// Run from the repository root: npx deno run --node-modules-dir=none --no-lock -A tool/manual_ai_summary_sql_test.mjs
import { PGlite } from "npm:@electric-sql/pglite@0.5.16";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
const db = new PGlite();
await db.exec(`
create role anon;create role authenticated;create role service_role;
create schema private;create schema vault;create schema extensions;create schema cron;create schema net;
create table private.clock(at timestamptz);insert into private.clock values('2026-11-18 13:59:00+00');
create function private.test_now() returns timestamptz language sql as $$select at from private.clock$$;
create function private.today() returns date language sql as $$select (private.test_now() at time zone 'Africa/Nairobi')::date$$;
create function extensions.gen_random_bytes(integer) returns bytea language sql as $$select decode(repeat('ab',$1),'hex')$$;
create table vault.decrypted_secrets(id uuid primary key default gen_random_uuid(),decrypted_secret text,name text);
create function vault.create_secret(text,text,text default null) returns uuid language sql as $$insert into vault.decrypted_secrets(decrypted_secret,name) values($1,$2) returning id$$;
create function vault.update_secret(uuid,text) returns void language sql as $$update vault.decrypted_secrets set decrypted_secret=$2 where id=$1$$;
create function net.http_post(url text,headers jsonb,body jsonb,timeout_milliseconds integer) returns bigint language sql as $$select 1::bigint$$;
create function cron.schedule(text,text,text) returns bigint language sql as $$select 1::bigint$$;
create table private.app_users(id bigint primary key,username text,full_name text,role text,active boolean);
insert into private.app_users values(1,'owner','Owner','admin',true),(2,'team','Team member','team',true),(3,'director','Director','director',true);
create function private.token_role(text) returns text language plpgsql as $$begin if $1='admin' then return 'admin';elsif $1 in ('team','director') then return $1;else raise exception 'not_signed_in' using errcode='28000';end if;end$$;
create function private.token_user(text) returns bigint language sql as $$select case $1 when 'admin' then 1 when 'team' then 2 when 'director' then 3 end::bigint$$;
create table public.client_counts(day_id bigint,staff_id bigint,new_clients int,existing_clients int);
create table public.work_days(id bigint,date text);create table public.staff_day_off(day_id bigint,staff_id bigint);
create table public.revenue_entries(date text,amount_cents bigint);create table public.app_settings(key text,value text);
create table public.applications(status text,offer_date text,coe_date text);
create table public.activity_reports(status text,review text,report_date date,submitted_at timestamptz,due_date date);
create table public.todo_team_items(done boolean,deleted boolean);create table public.staff(active int);create table public.weeks(id bigint);
insert into public.work_days values(1,'2026-11-18');insert into public.client_counts values(1,1,3,2),(1,2,100,0);insert into public.staff_day_off values(1,2);
insert into public.revenue_entries values('2026-11-18',10000),('2026-11-18',-1000);insert into public.app_settings values('currency','KES');
`);

for (
  const file of [
    "20261118080640_daily_ai_summary.sql",
    "20261118082030_ai_summary_job_auth_guard.sql",
    "20261118110032_manual_ai_summary.sql",
    "20261118113801_ai_report_failure_messages.sql",
    "20261118114826_report_readable_details.sql",
  ]
) {
  if (file.endsWith("manual_ai_summary.sql")) {
    await db.exec(
      `insert into private.ai_summaries(summary_date,status,run_id,lease_until,cutoff_at,generated_at,model,content,input_snapshot)
      values('2026-11-17','ready','00000000-0000-4000-8000-000000000099','2026-11-17 14:09:00+00','2026-11-17 14:05:00+00','2026-11-17 14:06:00+00','gemini-3.8-flash','{"brief":"Legacy scheduled report"}','{}')`,
    );
  }
  await db.exec(
    readFileSync("supabase/migrations/" + file, "utf8").replace(
      "create extension if not exists pg_net with schema extensions;",
      "",
    ).replaceAll("now()", "private.test_now()"),
  );
}
const scalar = async (sql, args = []) =>
  Object.values((await db.query(sql, args)).rows[0])[0];
assert.equal(
  await scalar("select model from private.ai_summary_config"),
  "gemini-3.5-flash-lite",
);
const context = await scalar("select private.ai_summary_context()");
assert.equal(context.revenue.today_amount, 90);
assert.equal(context.revenue.currency, "KES");
assert.equal(context.weekly_tracker.month_total, 5);
await db.exec("delete from public.app_settings where key='currency'");
assert.equal(
  (await scalar("select private.ai_summary_context()")).revenue.currency,
  "KSh",
);
const tick = async (time) => db.query("update private.clock set at=$1", [time]);
const request = () => scalar("select public.ai_summary_generate('admin')");
const read = () => scalar("select public.ai_summary_read('admin')");
let run = "00000000-0000-4000-8000-000000000001";
let run2 = "00000000-0000-4000-8000-000000000002";
await assert.rejects(request());
await db.query(
  "select public.ai_summary_configure('admin',false,'gemini-3.8-flash','{2,3}','test-key-1234567890123456789012345')",
);
for (const user of ["team", "director", "invalid"]) {
  await assert.rejects(
    db.query("select public.ai_summary_generate($1)", [user]),
  );
}
const token = await scalar(
  "select decrypted_secret from vault.decrypted_secrets where name='ai_summary_job_token'",
);
const claim = (job, id = run) =>
  scalar("select public.ai_summary_claim_job($1,$2,$3)", [token, id, job]);
const finish = (id, content, error = null) =>
  db.query("select public.ai_summary_finish($1,$2,$3)", [id, content, error]);
let job = await request();
assert.equal(job.status, "queued");
assert.equal(
  (await request()).job_id,
  job.job_id,
  "double click must not start another paid request",
);
let data = await read();
assert.equal(data.status, "queued");
assert.equal(data.can_generate, true);
assert.equal(data.enabled, false);
assert.equal(
  (await scalar("select public.ai_summary_read('team')")).can_generate,
  false,
);
await assert.rejects(
  db.query("select public.ai_summary_claim_job($1,$2,$3)", [
    "invalid",
    run,
    job.job_id,
  ]),
);
assert(
  await claim(job.job_id),
  "manual report must work before 5 pm with schedule off",
);
assert.equal(
  await claim(job.job_id, run2),
  null,
  "a dispatched request can only be claimed once",
);
await finish(run2, { brief: "wrong worker" });
assert.equal(
  (await read()).summaries.filter((r) => r.summary_date === "2026-11-18")
    .length,
  0,
);
assert.equal(
  (await read()).summaries[0].content.brief,
  "Legacy scheduled report",
);
await finish(run, { brief: "Morning report" });
data = await read();
assert.equal(data.summaries[0].content.brief, "Morning report");
assert(!JSON.stringify(data).includes("test-key"));
await tick("2026-11-18 14:00:00+00");
job = await request();
assert.equal(
  (await read()).summaries[0].content.brief,
  "Morning report",
  "queued refresh preserves published report",
);
assert(await claim(job.job_id, run2));
await finish(run2, null, "gemini_http_429");
data = await read();
assert.equal(data.status, "failed");
assert.match(data.error_message, /quota|rate limit/i);
assert.equal(
  data.summaries[0].content.brief,
  "Morning report",
  "failed refresh preserves published report",
);
await tick("2026-11-18 14:01:00+00");
job = await request();
run = crypto.randomUUID();
assert(await claim(job.job_id));
await tick("2026-11-18 14:06:00+00");
await finish(run, { brief: "Expired report" });
assert.equal((await read()).summaries[0].content.brief, "Morning report");
assert.equal((await read()).status, "failed");
// Neither a morning nor an after-5 pm manual report cancels the schedule.
job = await request();
run = crypto.randomUUID();
assert(await claim(job.job_id));
await finish(run, { brief: "Manual after 5 pm" });
await db.query(
  "select public.ai_summary_configure('admin',true,'gemini-3.8-flash','{2,3}')",
);
run2 = crypto.randomUUID();
assert(await claim(null, run2));
assert.equal(
  (await request()).status,
  "running",
  "manual cannot overlap scheduled generation",
);
await finish(run2, { brief: "Evening report" });
assert.equal(
  await claim(null),
  null,
  "already successful after-5 pm report suppresses duplicate scheduled generation",
);
await tick("2026-11-18 14:07:00+00");
job = await request();
run = crypto.randomUUID();
assert(await claim(job.job_id));
await finish(run, { brief: "Fresh manual report" });
assert.equal(
  (await read()).summaries[0].content.brief,
  "Fresh manual report",
  "manual can refresh an already successful day",
);
// Recheck the admin role if an account is demoted while a job is queued.
await tick("2026-11-18 14:08:00+00");
job = await request();
await db.exec("update private.app_users set role='team' where id=1");
assert.equal(await claim(job.job_id, run2), null);
assert.equal((await read()).status, "failed");
await db.exec("update private.app_users set role='admin' where id=1");
// Retry budget is per scheduled day, independent of manual requests.
for (let i = 0; i < 3; i++) {
  await tick(`2026-11-19 14:${String(5 + i * 10).padStart(2, "0")}:00+00`);
  run = crypto.randomUUID();
  assert(await claim(null));
  await finish(run, null, "generation_failed");
}
await tick("2026-11-19 14:36:00+00");
assert.equal(await claim(null), null);
// A job queued before midnight uses the data date at actual execution.
await tick("2026-11-19 20:59:50+00");
job = await request();
await tick("2026-11-19 21:00:10+00");
run = crypto.randomUUID();
const midnight = await claim(job.job_id);
assert.equal(midnight.date, "2026-11-20");
await finish(run, { brief: "New day report" });
assert.equal((await read()).summaries[0].summary_date, "2026-11-20");
await db.exec("set role anon");
await assert.rejects(
  db.query("select * from private.ai_summary_jobs"),
  (e) => e.code === "42501",
);
await assert.rejects(claim(null), (e) => e.code === "42501");
await assert.rejects(
  finish(run, { brief: "Unauthorized" }),
  (e) => e.code === "42501",
);
await db.exec("reset role");
await db.exec(
  "delete from vault.decrypted_secrets where name='ai_summary_job_token'",
);
await assert.rejects(claim(null), (e) => e.code === "42501");
await assert.rejects(request());
await db.close();
console.log(
  "Manual SQL checks passed: admin-only requests, anytime generation with schedule off, double-click protection, preserved reports on failure, fenced workers, evening schedule after morning refresh, role revocation, daily retry limits, midnight cutoff and private worker access.",
);
