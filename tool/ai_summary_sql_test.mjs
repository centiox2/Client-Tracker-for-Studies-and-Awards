// Run from the repository root: npx deno run --node-modules-dir=none --no-lock -A tool/ai_summary_sql_test.mjs
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
let migration = readFileSync(
  "supabase/migrations/20261118080640_daily_ai_summary.sql",
  "utf8",
).replace("create extension if not exists pg_net with schema extensions;", "")
  .replaceAll("now()", "private.test_now()");
await db.exec(migration);
await db.exec(
  readFileSync(
    "supabase/migrations/20261118082030_ai_summary_job_auth_guard.sql",
    "utf8",
  ).replaceAll("now()", "private.test_now()"),
);
const scalar = async (sql, args = []) =>
  Object.values((await db.query(sql, args)).rows[0])[0];
assert.equal(await scalar("select public.ai_summary_access('admin')"), true);
assert.equal(await scalar("select public.ai_summary_access('team')"), false);
for (const token of ["team", "director"]) {
  await assert.rejects(
    db.query("select public.ai_summary_read($1)", [token]),
    (e) => e.code === "42501",
  );
  await assert.rejects(
    db.query("select public.ai_summary_configure($1,false,$2,$3)", [
      token,
      "gemini-3.8-flash",
      [],
    ]),
    (e) => e.code === "42501",
  );
}
await assert.rejects(
  db.query("select public.ai_summary_access('invalid')"),
  (e) => e.code === "28000",
);
await assert.rejects(
  db.query(
    "select public.ai_summary_configure('admin',true,'gemini-3.8-flash','{}')",
  ),
);
await db.query(
  "select public.ai_summary_configure('admin',true,'gemini-3.8-flash','{2}','test-key-1234567890123456789012345')",
);
assert.equal(await scalar("select public.ai_summary_access('team')"), true);
let settings = await scalar("select public.ai_summary_settings('admin')");
assert.equal(settings.configured, true);
assert(!JSON.stringify(settings).includes("test-key"));
const token = await scalar(
  "select decrypted_secret from vault.decrypted_secrets where name='ai_summary_job_token'",
);
const run = "00000000-0000-4000-8000-000000000001",
  other = "00000000-0000-4000-8000-000000000002";
assert.equal(
  await scalar("select public.ai_summary_claim($1,$2)", [token, run]),
  null,
  "must not run before 5 pm",
);
await db.exec("update private.clock set at='2026-11-18 14:05:00+00'");
await assert.rejects(
  db.query("select public.ai_summary_claim($1,$2)", ["bad", run]),
  (e) => e.code === "42501",
);
let job = await scalar("select public.ai_summary_claim($1,$2)", [token, run]);
assert.equal(job.snapshot.weekly_tracker.today, 5);
assert.equal(job.snapshot.revenue.today_cents, 9000);
assert.equal(
  await scalar("select public.ai_summary_claim($1,$2)", [token, other]),
  null,
  "concurrent request must not duplicate generation",
);
await db.query("select public.ai_summary_finish($1,$2)", [other, {
  brief: "wrong run",
}]);
assert.equal(
  await scalar("select status from private.ai_summaries"),
  "running",
);
await db.query("select public.ai_summary_finish($1,$2)", [run, {
  brief: "Recorded totals.",
}]);
assert.equal(
  await scalar("select public.ai_summary_claim($1,$2)", [token, other]),
  null,
  "ready summary must not be overwritten",
);
const data = await scalar("select public.ai_summary_read('team')");
assert.equal(data.summaries.length, 1);
assert(!JSON.stringify(data).includes("test-key"));
await db.query(
  "select public.ai_summary_configure('admin',true,'gemini-3.8-flash','{}')",
);
await assert.rejects(
  db.query("select public.ai_summary_read('team')"),
  (e) => e.code === "42501",
);
await db.exec("set role anon");
await assert.rejects(
  db.query("select * from private.ai_summaries"),
  (e) => e.code === "42501",
);
await assert.rejects(
  db.query("select public.ai_summary_claim($1,$2)", [token, run]),
  (e) => e.code === "42501",
);
await assert.rejects(
  db.query("select public.ai_summary_finish($1)", [run]),
  (e) => e.code === "42501",
);
await db.exec("reset role");
// Exhausted failures stop after three attempts; expired workers cannot publish.
await db.exec("update private.clock set at='2026-11-19 14:05:00+00'");
for (let i = 0; i < 3; i++) {
  assert(await scalar("select public.ai_summary_claim($1,$2)", [token, run]));
  await db.exec("update private.clock set at=at+interval '10 minutes'");
  await db.query("select public.ai_summary_finish($1,$2)", [run, {
    brief: "Expired worker",
  }]);
  assert.equal(
    await scalar(
      "select status from private.ai_summaries where summary_date='2026-11-19'",
    ),
    "running",
  );
}
assert.equal(
  await scalar("select public.ai_summary_claim($1,$2)", [token, run]),
  null,
);
await db.exec(
  "delete from vault.decrypted_secrets where name='ai_summary_job_token'",
);
await assert.rejects(
  db.query("select public.ai_summary_claim($1,$2)", [token, run]),
  (e) => e.code === "42501",
);
await db.close();
console.log(
  "SQL checks passed: explicit assignments, admin-only configuration, secret isolation, after-5pm gate, net totals, off-day exclusion, concurrency fencing, revocation, bounded retries and expired workers.",
);
