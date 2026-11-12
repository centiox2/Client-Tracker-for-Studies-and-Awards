-- ===== Daily report search ignores punctuation (2026-11-12) =====
-- "o'brien", "O. Brien" and "obrien" find the same report; commas, full
-- stops and dashes in a search no longer stop it matching. Every word of
-- the search must appear (in any order) in the description, reference,
-- next action or blocker.

create or replace function private.search_key(p_text text)
returns text language sql immutable set search_path = '' as $$
  select regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9]+', '', 'g');
$$;

create or replace function private.search_hit(p_search text, p_text text)
returns boolean language sql immutable set search_path = '' as $$
  select not exists (
    select 1
    from regexp_split_to_table(
           lower(regexp_replace(coalesce(p_search, ''), '[''’`]', '', 'g')),
           '[^a-z0-9]+') w
    where w <> '' and position(w in private.search_key(p_text)) = 0);
$$;

do $$
declare src text;
begin
  src := pg_get_functiondef('public.report_list(text, jsonb)'::regprocedure);
  if position('search_hit' in src) = 0 then
    src := regexp_replace(src,
      'and \(v_search is null.*?r\.blocker ilike ''%'' \|\| v_search \|\| ''%''\)',
      'and (v_search is null or private.search_hit(v_search, concat_ws('' '', '
        || 'r.description, r.reference, r.next_action, r.blocker)))');
    if position('search_hit' in src) = 0 then
      raise exception 'report_list search clause not found';
    end if;
    execute src;
  end if;
end $$;

revoke all on function private.search_key(text), private.search_hit(text, text)
  from public, anon, authenticated;
