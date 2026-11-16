-- Personal to-do lists, kept per account so every device signed in as the
-- same person shows the same list. Only reachable through the two
-- functions below (the signed-in person's token decides whose list).
--
-- Each item carries the time the app last changed it; a save only replaces
-- an item when it is newer, so two devices editing different items never
-- undo each other. Deleted items are kept briefly as "deleted" so a device
-- that was offline doesn't bring them back.

create table if not exists public.todo_items (
  user_id bigint not null references private.app_users(id) on delete cascade,
  id bigint not null,
  title text not null check (length(title) between 1 and 300),
  done boolean not null default false,
  done_at timestamptz,
  sent_id bigint,
  deleted boolean not null default false,
  changed_at timestamptz not null,
  primary key (user_id, id)
);
alter table public.todo_items enable row level security;
revoke all on public.todo_items from anon, authenticated;

-- The person's list (deleted items left out), oldest first.
create or replace function public.todo_list(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
begin
  delete from public.todo_items
    where user_id = me and deleted and changed_at < now() - interval '30 days';
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', t.id, 'title', t.title, 'done', t.done, 'done_at', t.done_at,
        'sent_id', t.sent_id, 'changed_at', t.changed_at)
      order by t.id)
    from public.todo_items t
    where t.user_id = me and not t.deleted), '[]'::jsonb);
end $$;

-- Saves changed items: [{id, title, done, done_at, sent_id, deleted,
-- changed_at}]. Returns the list as it now stands.
create or replace function public.todo_save(p_token text, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  me bigint := private.token_user(p_token);
  n int;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  select count(*) into n from public.todo_items
    where user_id = me and not deleted;
  if n + jsonb_array_length(p_items) > 2000 then
    raise exception 'too_many_items' using errcode = '22023';
  end if;

  insert into public.todo_items as t
      (user_id, id, title, done, done_at, sent_id, deleted, changed_at)
  select me,
         (i->>'id')::bigint,
         left(coalesce(nullif(trim(i->>'title'), ''), '(untitled)'), 300),
         coalesce((i->>'done')::boolean, false),
         (i->>'done_at')::timestamptz,
         (i->>'sent_id')::bigint,
         coalesce((i->>'deleted')::boolean, false),
         -- A clock far ahead can't pin an item forever.
         least(coalesce((i->>'changed_at')::timestamptz, now()),
               now() + interval '5 minutes')
    from jsonb_array_elements(p_items) i
  on conflict (user_id, id) do update
    set title = excluded.title,
        done = excluded.done,
        done_at = excluded.done_at,
        sent_id = coalesce(excluded.sent_id, t.sent_id),
        deleted = excluded.deleted,
        changed_at = excluded.changed_at
    where excluded.changed_at >= t.changed_at;

  return public.todo_list(p_token);
end $$;

revoke all on function public.todo_list(text) from public;
revoke all on function public.todo_save(text, jsonb) from public;
grant execute on function public.todo_list(text) to anon, authenticated;
grant execute on function public.todo_save(text, jsonb) to anon, authenticated;
