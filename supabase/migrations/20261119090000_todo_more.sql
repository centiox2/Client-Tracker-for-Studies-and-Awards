-- To-do, round two:
--  * items keep their extra details (planned day, deadline, star, order,
--    repeat, notes, steps, counts, client link, who gave it…) in "extra";
--  * each department has a shared list everyone in it can see and tick;
--  * a to-do can be given to a colleague (it lands on their list);
--  * an item sent to Daily reports ticks itself once that task is done,
--    and shows how the task is doing (awaiting review, approved…).
-- todo_list / todo_save stay as they were for 1.7.0 apps; newer apps use
-- todo_sync.

alter table public.todo_items
  add column if not exists extra jsonb not null default '{}'::jsonb;

create table if not exists public.todo_team_items (
  department_id bigint not null references public.departments(id) on delete cascade,
  id bigint not null,
  title text not null check (length(title) between 1 and 300),
  done boolean not null default false,
  done_at timestamptz,
  deleted boolean not null default false,
  changed_at timestamptz not null,
  changed_by bigint references private.app_users(id) on delete set null,
  extra jsonb not null default '{}'::jsonb,
  primary key (department_id, id)
);
alter table public.todo_team_items enable row level security;
revoke all on public.todo_team_items from anon, authenticated;

-- Extra details are the app's; only their size is checked.
create or replace function private.todo_extra(p jsonb)
returns jsonb language sql immutable set search_path to '' as $$
  select case
    when p is null or jsonb_typeof(p) <> 'object' then '{}'::jsonb
    when length(p::text) > 20000 then '{}'::jsonb
    else p end
$$;

create or replace function public.todo_sync(p_token text, p_items jsonb default '[]'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  v_dept bigint;
  n int;
begin
  select department_id into v_dept from private.app_users where id = me;
  if p_items is null then p_items := '[]'::jsonb; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  select count(*) into n from public.todo_items where user_id = me and not deleted;
  if n + jsonb_array_length(p_items) > 3000 then
    raise exception 'too_many_items' using errcode = '22023';
  end if;

  -- My own items.
  insert into public.todo_items as t
      (user_id, id, title, done, done_at, sent_id, deleted, changed_at, extra)
  select me,
         (i->>'id')::bigint,
         left(coalesce(nullif(trim(i->>'title'), ''), '(untitled)'), 300),
         coalesce((i->>'done')::boolean, false),
         (i->>'done_at')::timestamptz,
         (i->>'sent_id')::bigint,
         coalesce((i->>'deleted')::boolean, false),
         least(coalesce((i->>'changed_at')::timestamptz, now()),
               now() + interval '5 minutes'),
         private.todo_extra(i->'extra')
    from jsonb_array_elements(p_items) i
   where not coalesce((i->>'team')::boolean, false)
  on conflict (user_id, id) do update
    set title = excluded.title,
        done = excluded.done,
        done_at = excluded.done_at,
        sent_id = coalesce(excluded.sent_id, t.sent_id),
        deleted = excluded.deleted,
        changed_at = excluded.changed_at,
        extra = excluded.extra
    where excluded.changed_at >= t.changed_at;

  -- The department's shared list.
  if v_dept is not null then
    insert into public.todo_team_items as t
        (department_id, id, title, done, done_at, deleted, changed_at,
         changed_by, extra)
    select v_dept,
           (i->>'id')::bigint,
           left(coalesce(nullif(trim(i->>'title'), ''), '(untitled)'), 300),
           coalesce((i->>'done')::boolean, false),
           (i->>'done_at')::timestamptz,
           coalesce((i->>'deleted')::boolean, false),
           least(coalesce((i->>'changed_at')::timestamptz, now()),
                 now() + interval '5 minutes'),
           me,
           private.todo_extra(i->'extra')
      from jsonb_array_elements(p_items) i
     where coalesce((i->>'team')::boolean, false)
    on conflict (department_id, id) do update
      set title = excluded.title,
          done = excluded.done,
          done_at = excluded.done_at,
          deleted = excluded.deleted,
          changed_at = excluded.changed_at,
          changed_by = excluded.changed_by,
          extra = excluded.extra
      where excluded.changed_at >= t.changed_at;
  end if;

  -- Sent to Daily reports and finished there: ticked here too (once, so
  -- unticking it again sticks).
  update public.todo_items t
     set done = true,
         done_at = coalesce(t.done_at, now()),
         changed_at = now(),
         extra = t.extra || '{"auto_ticked": true}'::jsonb
    from public.activity_reports r
   where t.user_id = me and not t.done and not t.deleted
     and not (t.extra ? 'auto_ticked')
     and r.id = t.sent_id and r.user_id = me
     and r.status = 'done' and r.review in ('submitted', 'approved');

  -- Old deletions and long-cleared items go.
  delete from public.todo_items
   where user_id = me and (
     (deleted and changed_at < now() - interval '30 days') or
     (done and coalesce((extra->>'archived')::boolean, false)
      and done_at < now() - interval '90 days'));
  if v_dept is not null then
    delete from public.todo_team_items
     where department_id = v_dept and (
       (deleted and changed_at < now() - interval '30 days') or
       (done and done_at < now() - interval '90 days'));
  end if;

  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', t.id, 'title', t.title, 'done', t.done, 'done_at', t.done_at,
          'sent_id', t.sent_id, 'changed_at', t.changed_at, 'extra', t.extra,
          'report_review', r.review, 'report_status', r.status)
        order by t.id)
      from public.todo_items t
      left join public.activity_reports r
        on r.id = t.sent_id and r.user_id = me
      where t.user_id = me and not t.deleted), '[]'::jsonb),
    'team', case when v_dept is null then null else jsonb_build_object(
      'id', v_dept,
      'name', (select d.name from public.departments d where d.id = v_dept),
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', t.id, 'title', t.title, 'done', t.done,
            'done_at', t.done_at, 'changed_at', t.changed_at,
            'extra', t.extra, 'team', true,
            'changed_by_name', u.full_name)
          order by t.id)
        from public.todo_team_items t
        left join private.app_users u on u.id = t.changed_by
        where t.department_id = v_dept and not t.deleted), '[]'::jsonb))
    end);
end $$;

-- Who a to-do can be given to: everyone else with an active account.
create or replace function public.todo_people(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', u.id, 'name', u.full_name, 'department', d.name)
      order by lower(u.full_name))
    from private.app_users u
    left join public.departments d on d.id = u.department_id
    where u.active and u.id <> me), '[]'::jsonb);
end $$;

-- Puts a to-do on a colleague's list, marked as from me (and new).
create or replace function public.todo_give(p_token text, p_user bigint, p_item jsonb)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  v_name text;
  v_title text := left(trim(coalesce(p_item->>'title', '')), 300);
  n int;
begin
  if length(v_title) = 0 then
    raise exception 'title_required' using errcode = '22023';
  end if;
  if not exists (select 1 from private.app_users where id = p_user and active)
     or p_user = me then
    raise exception 'unknown_user' using errcode = '22023';
  end if;
  select count(*) into n from public.todo_items
   where user_id = p_user and not deleted;
  if n >= 3000 then
    raise exception 'too_many_items' using errcode = '22023';
  end if;
  select full_name into v_name from private.app_users where id = me;
  insert into public.todo_items (user_id, id, title, changed_at, extra)
  values (
    p_user,
    (extract(epoch from clock_timestamp()) * 1000000)::bigint
      + floor(random() * 1000)::bigint,
    v_title,
    now(),
    private.todo_extra(
      jsonb_strip_nulls(jsonb_build_object(
        'notes', left(p_item->>'notes', 2000),
        'day', p_item->'day',
        'due', p_item->'due',
        'starred', p_item->'starred',
        'steps', p_item->'steps',
        'client', p_item->'client'))
      || jsonb_build_object(
        'from', jsonb_build_object('id', me, 'name', v_name),
        'new', true)))
  on conflict do nothing;
end $$;

revoke all on function public.todo_sync(text, jsonb) from public;
revoke all on function public.todo_people(text) from public;
revoke all on function public.todo_give(text, bigint, jsonb) from public;
revoke all on function private.todo_extra(jsonb) from public;
grant execute on function public.todo_sync(text, jsonb) to anon, authenticated;
grant execute on function public.todo_people(text) to anon, authenticated;
grant execute on function public.todo_give(text, bigint, jsonb) to anon, authenticated;
