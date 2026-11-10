-- ===== Applications from Airtable (2026-11-10) =====
-- The online database reads the Airtable "Applications Tracker" itself, so
-- nobody has to export and upload a CSV. The token is in the Vault
-- (secret "airtable_token", read-only). Airtable's free plan allows 1,000
-- API calls a month per workspace, so:
--   * every 30 minutes in working hours only what changed is read
--     (one call, usually);
--   * every night everything is read (about one call per 100 records),
--     which also catches deleted records;
--   * the calls are counted, and the schedule slows down and then stops
--     before the limit (the CSV upload in the app still works).
-- What changed is noted exactly as a CSV upload notes it
-- (application_imports, application_changes), with the same keys.

create extension if not exists http with schema extensions;
create extension if not exists pg_cron;

-- Calls per month (Kenya time).
create table if not exists private.airtable_usage (
  month date primary key,
  calls integer not null default 0
);

-- What to read, and which Airtable field is which column. Fields are by ID,
-- so renaming a column in Airtable doesn't break anything.
create table if not exists private.airtable_config (
  id         integer primary key default 1 check (id = 1),
  base_id    text not null,
  table_id   text not null,
  view_id    text not null,
  fields     jsonb not null,
  enabled    boolean not null default false   -- switched on once checked
);
insert into private.airtable_config (id, base_id, table_id, view_id, fields)
values (1, 'appIohpumIL9A0S6I', 'tbl70dKK7cS4qg2nv', 'viwWTcXq51ZU9ogLo',
  '{"student":"fldqRDr6bYHemY5Jp","rto":"fldmOOpIKYYmotxLq",
    "country":"flduT37ZU1qT2oxfj","doc_date":"fld9fk1b4KS3m29Da",
    "app_date":"fldTwdFJdAb6mG5Xj","offer_date":"fldfM6DHHcxFbgG7A",
    "coe_date":"fldWX9dyqMPJRccg5","status":"fldaJhoOjVZJTuZ9d",
    "assignee":"fldD5mwyrmAEkISGy","todo":"fldx7eZYxaUfePGnQ",
    "follow_up":"fldI6vaEWxJOSublh"}')
on conflict (id) do nothing;

-- How the sync is doing.
create table if not exists private.airtable_state (
  id            integer primary key default 1 check (id = 1),
  cursor_at     timestamptz,          -- changes after this are read next
  last_run_at   timestamptz,
  last_ok_at    timestamptz,
  last_full_at  timestamptz,
  last_kind     text,
  last_result   jsonb,
  last_error    text,
  last_error_at timestamptz
);
insert into private.airtable_state (id) values (1) on conflict (id) do nothing;

-- The Airtable records as last read, in the view's order.
create table if not exists private.airtable_records (
  rec_id    text primary key,
  fields    jsonb not null,
  position  integer not null,
  read_at   timestamptz not null default now()
);

-- GET https://api.airtable.com/v0/<path> with the Vault token; counts the
-- call. Returns {status, body}.
create or replace function private.airtable_get(p_path text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_token text;
  v_resp extensions.http_response;
  v_month date := date_trunc('month', now() at time zone 'Africa/Nairobi')::date;
begin
  select decrypted_secret into v_token
    from vault.decrypted_secrets where name = 'airtable_token' limit 1;
  if v_token is null then
    raise exception 'no_airtable_token' using errcode = 'P0001';
  end if;
  insert into private.airtable_usage as u (month, calls) values (v_month, 1)
    on conflict (month) do update set calls = u.calls + 1;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '30');
  select * into v_resp from extensions.http((
    'GET',
    'https://api.airtable.com/v0/' || p_path,
    array[extensions.http_header('Authorization', 'Bearer ' || v_token)],
    null, null)::extensions.http_request);
  return jsonb_build_object(
    'status', v_resp.status,
    'body', case when v_resp.content is null or v_resp.content = '' then null
                 else v_resp.content::jsonb end);
end $$;

create or replace function private.airtable_calls_this_month()
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce((select calls from private.airtable_usage
    where month = date_trunc('month', now() at time zone 'Africa/Nairobi')::date), 0);
$$;

-- Kenya local time as the app writes it ("2026-11-10T14:06:47.865654").
create or replace function private.kenya_now_text()
returns text language sql stable set search_path = '' as $$
  select to_char(now() at time zone 'Africa/Nairobi', 'YYYY-MM-DD"T"HH24:MI:SS.US');
$$;

-- Trims, and (unless p_keep_lines) folds runs of spaces / line breaks into
-- one space — the CSV upload's clean-up.
create or replace function private.airtable_text(p_value jsonb, p_keep_lines boolean default false)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_value is null or jsonb_typeof(p_value) = 'null' then ''
    when p_keep_lines then regexp_replace(
      case jsonb_typeof(p_value) when 'string' then p_value #>> '{}' else p_value::text end,
      '^\s+|\s+$', '', 'g')
    else btrim(regexp_replace(
      case jsonb_typeof(p_value)
        when 'string' then p_value #>> '{}'
        -- a list (several options, linked names): joined with commas
        when 'array' then (select string_agg(coalesce(e->>'name', e #>> '{}'), ', ')
                             from jsonb_array_elements(p_value) e)
        when 'object' then coalesce(p_value->>'name', p_value::text)
        else p_value #>> '{}' end,
      '\s+', ' ', 'g'))
  end;
$$;

-- "2026-02-02" (or a date-time) → "2026-02-02"; null when empty or odd.
create or replace function private.airtable_date(p_value jsonb)
returns text language plpgsql immutable set search_path = '' as $$
declare s text := p_value #>> '{}';
begin
  if s is null or s !~ '^\d{4}-\d{2}-\d{2}' then return null; end if;
  return to_char(left(s, 10)::date, 'YYYY-MM-DD');
exception when others then
  return null;
end $$;

-- Reads Airtable into private.airtable_records. p_full: everything (and
-- drops records no longer there); otherwise only records changed since the
-- last read. Returns {calls, read}.
create or replace function private.airtable_fetch(p_full boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c private.airtable_config;
  s private.airtable_state;
  v_started timestamptz := now();
  v_path text;
  v_offset text;
  v_resp jsonb;
  v_status int;
  v_calls int := 0;
  v_read int := 0;
  v_pos int := 0;
  v_next_pos int;
  v_fields text := '';
  v_seen text[] := '{}';
  rec jsonb;
  f text;
begin
  select * into c from private.airtable_config where id = 1;
  select * into s from private.airtable_state where id = 1;
  for f in select value from jsonb_each_text(c.fields) loop
    v_fields := v_fields || '&fields%5B%5D=' || f;
  end loop;
  if not p_full and s.cursor_at is null then
    p_full := true;                    -- never read: read everything
  end if;
  select coalesce(max(position), -1) + 1 into v_next_pos from private.airtable_records;

  loop
    v_path := c.base_id || '/' || c.table_id || '?view=' || c.view_id
      || '&pageSize=100&returnFieldsByFieldId=true' || v_fields;
    if not p_full then
      -- A minute's overlap, so a change made during the last read is caught.
      v_path := v_path || '&filterByFormula=' || extensions.urlencode(format(
        'IS_AFTER(LAST_MODIFIED_TIME(), ''%s'')',
        to_char((s.cursor_at - interval '1 minute') at time zone 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS.000"Z"')));
    end if;
    if v_offset is not null then
      v_path := v_path || '&offset=' || extensions.urlencode(v_offset);
    end if;
    v_resp := private.airtable_get(v_path);
    v_calls := v_calls + 1;
    v_status := (v_resp->>'status')::int;
    if v_status <> 200 then
      raise exception '%', case
        when v_status in (401, 403) then 'airtable_token_rejected'
        when v_status = 404 then 'airtable_not_found'
        when v_status = 429 then 'airtable_limit'
        else 'airtable_error_' || v_status end
        using errcode = 'P0001',
              detail = coalesce(v_resp->'body'->'error'->>'message',
                                v_resp->'body'->>'error', '');
    end if;
    for rec in select value from jsonb_array_elements(v_resp->'body'->'records') loop
      v_read := v_read + 1;
      v_seen := v_seen || (rec->>'id');
      if p_full then
        insert into private.airtable_records as r (rec_id, fields, position, read_at)
          values (rec->>'id', coalesce(rec->'fields', '{}'), v_pos, v_started)
          on conflict (rec_id) do update
            set fields = excluded.fields, position = excluded.position, read_at = excluded.read_at;
        v_pos := v_pos + 1;
      else
        -- Changed records keep their place; new ones go at the end (where
        -- Airtable puts them) until the night's full read.
        insert into private.airtable_records as r (rec_id, fields, position, read_at)
          values (rec->>'id', coalesce(rec->'fields', '{}'), v_next_pos, v_started)
          on conflict (rec_id) do update
            set fields = excluded.fields, read_at = excluded.read_at;
        if found then v_next_pos := v_next_pos + 1; end if;
      end if;
    end loop;
    v_offset := v_resp->'body'->>'offset';
    exit when v_offset is null;
    if v_calls >= 20 then              -- 2,000 records: something's wrong
      raise exception 'airtable_too_many_pages' using errcode = 'P0001';
    end if;
    perform pg_sleep(0.25);            -- Airtable: at most 5 calls a second
  end loop;

  if p_full then
    delete from private.airtable_records where not (rec_id = any (v_seen));
  end if;
  update private.airtable_state
    set cursor_at = v_started,
        last_full_at = case when p_full then v_started else last_full_at end
    where id = 1;
  return jsonb_build_object('calls', v_calls, 'read', v_read, 'full', p_full);
end $$;

-- A new row id like the app's (microseconds), above every id in use.
create or replace function private.applications_next_id()
returns bigint language sql volatile security definer set search_path = '' as $$
  select greatest(
    (extract(epoch from clock_timestamp()) * 1000000)::bigint,
    coalesce((select max(id) from public.applications), 0) + 1,
    coalesce((select max(id) from public.application_imports), 0) + 1,
    coalesce((select max(id) from public.application_changes), 0) + 1);
$$;

-- Brings public.applications in line with private.airtable_records, the way
-- the app's CSV upload does (ApplicationRepository.importCsv): same keys,
-- same "what changed" notes. Writes an import entry only when something
-- changed. Returns {total, added, changed, removed, first}.
create or replace function private.applications_apply(p_label text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c private.airtable_config;
  v_now text := private.kenya_now_text();
  v_first boolean;
  v_total int;
  v_added int;
  v_changed int;
  v_removed int;
  v_import bigint;
  v_base bigint;
  m record;
  fields text[] := array['rto','country','doc_date','app_date','offer_date',
    'coe_date','status','assignee','todo','follow_up'];
begin
  select * into c from private.airtable_config where id = 1;
  perform set_config('client_min_messages', 'warning', true);
  drop table if exists _in, _diff, _new, _gone;
  v_first := not exists (select 1 from public.applications)
         and not exists (select 1 from public.application_imports);

  -- The incoming applications, cleaned like the CSV.
  create temp table _in on commit drop as
  with raw as (
    select r.position, r.rec_id,
      private.airtable_text(r.fields->(c.fields->>'student')) as student,
      private.airtable_text(r.fields->(c.fields->>'rto')) as rto,
      private.airtable_text(r.fields->(c.fields->>'country')) as country,
      private.airtable_date(r.fields->(c.fields->>'doc_date')) as doc_date,
      private.airtable_date(r.fields->(c.fields->>'app_date')) as app_date,
      private.airtable_date(r.fields->(c.fields->>'offer_date')) as offer_date,
      private.airtable_date(r.fields->(c.fields->>'coe_date')) as coe_date,
      private.airtable_text(r.fields->(c.fields->>'status')) as status,
      private.airtable_text(r.fields->(c.fields->>'assignee')) as assignee,
      private.airtable_text(r.fields->(c.fields->>'todo'), true) as todo,
      private.airtable_text(r.fields->(c.fields->>'follow_up'), true) as follow_up
    from private.airtable_records r
  ), kept as (
    select raw.*,
      (row_number() over (order by position, rec_id) - 1)::int as pos,
      lower(student) as base,
      lower(concat_ws(' · ', nullif(rto, ''), nullif(country, ''))) as place
    from raw where student <> ''
  ), places as (
    select base, count(distinct place) as n from kept group by base
  ), keyed as (
    select k.*, case when p.n > 1 and k.place <> '' then k.base || ' · ' || k.place
                     else k.base end as key0
    from kept k join places p using (base)
  )
  select keyed.*,
    case when row_number() over (partition by key0 order by pos) = 1 then key0
         else key0 || ' #' || row_number() over (partition by key0 order by pos) end as app_key
  from keyed;

  v_total := (select count(*) from _in);
  if v_total = 0 then
    -- An empty read never wipes the applications (Airtable hiccup, wrong
    -- view): it's refused instead.
    raise exception 'airtable_empty' using errcode = 'P0001';
  end if;

  -- Same-name students used to be told apart by their order; a stored
  -- application under an old key that matches an incoming one on name,
  -- institution and country takes the new key, with its history.
  for m in
    select distinct on (a.app_key) i.app_key as new_key, a.app_key as old_key
    from _in i
    join public.applications a
      on lower(a.student) = lower(i.student) and lower(a.rto) = lower(i.rto)
     and lower(a.country) = lower(i.country)
    where not exists (select 1 from public.applications x where x.app_key = i.app_key)
      and not exists (select 1 from _in y where y.app_key = a.app_key)
    order by a.app_key, i.pos
  loop
    if exists (select 1 from public.applications where app_key = m.new_key) then
      continue;                         -- taken by an earlier match
    end if;
    update public.applications set app_key = m.new_key where app_key = m.old_key;
    update public.application_changes set app_key = m.new_key where app_key = m.old_key;
  end loop;

  -- What differs.
  create temp table _diff on commit drop as
  select i.app_key, i.student, f.field, coalesce(f.old, '') as old_value,
         coalesce(f.new, '') as new_value
  from _in i
  join public.applications a on a.app_key = i.app_key
  cross join lateral (values
    ('rto', a.rto, i.rto), ('country', a.country, i.country),
    ('doc_date', a.doc_date, i.doc_date), ('app_date', a.app_date, i.app_date),
    ('offer_date', a.offer_date, i.offer_date), ('coe_date', a.coe_date, i.coe_date),
    ('status', a.status, i.status), ('assignee', a.assignee, i.assignee),
    ('todo', a.todo, i.todo), ('follow_up', a.follow_up, i.follow_up)
  ) as f(field, old, new)
  where coalesce(f.old, '') <> coalesce(f.new, '');

  create temp table _new on commit drop as
  select i.app_key from _in i
  where not exists (select 1 from public.applications a where a.app_key = i.app_key);
  create temp table _gone on commit drop as
  select a.app_key, a.student, a.status from public.applications a
  where not exists (select 1 from _in i where i.app_key = a.app_key);
  v_added := (select count(*) from _new);
  v_removed := (select count(*) from _gone);
  v_changed := (select count(distinct app_key) from _diff);

  -- Each statement only when it has something to do (every write tells the
  -- devices to download again).
  if exists (
       select 1 from _in i join public.applications a on a.app_key = i.app_key
       where a.position <> i.pos or a.student <> i.student
          or exists (select 1 from _diff d where d.app_key = i.app_key)) then
    update public.applications a set
      student = i.student, rto = i.rto, country = i.country,
      doc_date = i.doc_date, app_date = i.app_date, offer_date = i.offer_date,
      coe_date = i.coe_date, status = i.status, assignee = i.assignee,
      todo = i.todo, follow_up = i.follow_up, position = i.pos,
      updated_at = case when exists (select 1 from _diff d where d.app_key = i.app_key)
                        then v_now else a.updated_at end
    from _in i
    where a.app_key = i.app_key
      and (a.position <> i.pos or a.student <> i.student
           or exists (select 1 from _diff d where d.app_key = i.app_key));
  end if;

  if v_added > 0 then
    v_base := private.applications_next_id();
    insert into public.applications (id, app_key, student, rto, country,
      doc_date, app_date, offer_date, coe_date, status, assignee, todo,
      follow_up, position, updated_at)
    select v_base + row_number() over (order by i.pos), i.app_key, i.student,
      i.rto, i.country, i.doc_date, i.app_date, i.offer_date, i.coe_date,
      i.status, i.assignee, i.todo, i.follow_up, i.pos, v_now
    from _in i join _new n using (app_key);
  end if;

  if v_removed > 0 then
    delete from public.applications a using _gone g where a.app_key = g.app_key;
  end if;

  if v_first or v_added + v_changed + v_removed > 0 then
    v_import := private.applications_next_id();
    insert into public.application_imports (id, imported_at, file_name, total,
      added, changed, removed, device)
    values (v_import, v_now, p_label, v_total, v_added, v_changed, v_removed,
            'Airtable sync');
    if not v_first then
      v_base := private.applications_next_id();
      -- In the CSV upload's order: each application in turn (added, or its
      -- changed fields), then the removed ones.
      insert into public.application_changes (id, import_id, app_key, student,
        field, old_value, new_value, changed_at)
      select v_base + row_number() over (order by grp, pos, ord), v_import,
        app_key, student, field, old_value, new_value, v_now
      from (
        select 1 as grp, i.pos, 0 as ord, i.app_key, i.student,
               'added' as field, '' as old_value, i.status as new_value
        from _in i join _new n using (app_key)
        union all
        select 1, i.pos, array_position(fields, d.field), d.app_key,
               d.student, d.field, d.old_value, d.new_value
        from _diff d join _in i using (app_key)
        union all
        select 2, 0, 0, g.app_key, g.student, 'removed', g.status, ''
        from _gone g
      ) ch;
    end if;
  end if;

  return jsonb_build_object('total', v_total, 'added', v_added,
    'changed', v_changed, 'removed', v_removed, 'first', v_first);
end $$;
-- Monthly budget (Airtable free plan: 1,000 calls per workspace). Above
-- these, the schedule slows down and then stops until the 1st; "Sync now"
-- keeps a small reserve.
create or replace function private.airtable_budget()
returns jsonb language sql immutable set search_path = '' as $$
  select '{"limit": 1000, "slow": 700, "stop_changes": 850,
           "stop_nightly": 920, "stop_manual": 980}'::jsonb;
$$;

-- One sync: reads Airtable (p_kind 'changes', 'full'), applies it, notes the
-- result. Only one at a time. Returns the result, or {skipped: reason}.
-- Errors are noted and returned ({error: code}), never raised, so the
-- schedule keeps going.
create or replace function private.airtable_run(p_kind text, p_label text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_fetch jsonb;
  v_apply jsonb;
  v_result jsonb;
  v_code text;
  v_detail text;
begin
  if not coalesce((select enabled from private.airtable_config where id = 1), false) then
    return jsonb_build_object('skipped', 'disabled');
  end if;
  if not pg_try_advisory_xact_lock(hashtext('airtable_sync')) then
    return jsonb_build_object('skipped', 'busy');
  end if;
  update private.airtable_state set last_run_at = now(), last_kind = p_kind where id = 1;
  begin
    v_fetch := private.airtable_fetch(p_kind = 'full');
    v_apply := private.applications_apply(p_label);
    v_result := v_apply || v_fetch;
    update private.airtable_state
      set last_ok_at = now(), last_result = v_result, last_error = null
      where id = 1;
    return v_result;
  exception when others then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    -- The error undid the call count too: count at least the call that
    -- failed (the pages read before it can't be known here).
    if v_code like 'airtable\_%' then
      insert into private.airtable_usage as u (month, calls)
        values (date_trunc('month', now() at time zone 'Africa/Nairobi')::date, 1)
        on conflict (month) do update set calls = u.calls + 1;
    end if;
    update private.airtable_state
      set last_error = v_code || case when coalesce(v_detail, '') <> ''
                                      then ': ' || v_detail else '' end,
          last_error_at = now()
      where id = 1;
    return jsonb_build_object('error', v_code);
  end;
end $$;

-- What the schedule calls. 'changes' every 30 minutes in working hours,
-- 'full' at night; each checks the budget first.
create or replace function private.airtable_scheduled(p_kind text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b jsonb := private.airtable_budget();
  used int := private.airtable_calls_this_month();
  s private.airtable_state;
begin
  select * into s from private.airtable_state where id = 1;
  if p_kind = 'full' then
    if used >= (b->>'stop_nightly')::int then
      return jsonb_build_object('skipped', 'budget');
    end if;
    return private.airtable_run('full', 'Airtable (nightly)');
  end if;
  if used >= (b->>'stop_changes')::int then
    return jsonb_build_object('skipped', 'budget');
  end if;
  -- Over the "slow" mark: once an hour instead of every 30 minutes.
  if used >= (b->>'slow')::int and s.last_run_at > now() - interval '50 minutes' then
    return jsonb_build_object('skipped', 'slow');
  end if;
  return private.airtable_run('changes', 'Airtable');
end $$;

-- For the app: how the Airtable sync is doing (any signed-in person).
create or replace function public.airtable_status(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  s private.airtable_state;
  b jsonb := private.airtable_budget();
begin
  perform private.token_role(p_token);
  select * into s from private.airtable_state where id = 1;
  return jsonb_build_object(
    'enabled', coalesce((select enabled from private.airtable_config where id = 1), false),
    'last_ok_at', s.last_ok_at,
    'last_full_at', s.last_full_at,
    'last_run_at', s.last_run_at,
    'last_result', s.last_result,
    'last_error', s.last_error,
    'last_error_at', s.last_error_at,
    'calls_this_month', private.airtable_calls_this_month(),
    'limit', (b->>'limit')::int,
    'slow_at', (b->>'slow')::int,
    'stop_at', (b->>'stop_changes')::int,
    'manual_stop_at', (b->>'stop_manual')::int);
end $$;

-- "Sync now" (admin and admin team): reads what changed since the last
-- read; p_full (admin only) reads everything, which also catches records
-- deleted in Airtable.
create or replace function public.airtable_sync_now(p_token text, p_full boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r text := private.token_role(p_token);
  b jsonb := private.airtable_budget();
begin
  if r not in ('admin', 'admin_team') or (p_full and r <> 'admin') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if private.airtable_calls_this_month() >= (b->>'stop_manual')::int then
    raise exception 'airtable_budget' using errcode = 'P0001';
  end if;
  return private.airtable_run(case when p_full then 'full' else 'changes' end,
                              'Airtable (Sync now)');
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function public.airtable_status(text) from public;
revoke all on function public.airtable_sync_now(text, boolean) from public;
grant execute on function public.airtable_status(text) to anon, authenticated;
grant execute on function public.airtable_sync_now(text, boolean) to anon, authenticated;

-- The schedule (UTC; Kenya is UTC+3). Changes: every 30 minutes from 08:00
-- to 18:30 Kenya time, Monday to Saturday. Everything: 02:00 Kenya time.
do $$
begin
  perform cron.unschedule(jobname) from cron.job
    where jobname in ('airtable-changes', 'airtable-nightly');
  perform cron.schedule('airtable-changes', '*/30 5-15 * * 1-6',
    $job$select private.airtable_scheduled('changes')$job$);
  perform cron.schedule('airtable-nightly', '0 23 * * *',
    $job$select private.airtable_scheduled('full')$job$);
end $$;
