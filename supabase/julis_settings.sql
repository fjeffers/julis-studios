-- Juli's Studios: shared shop settings + server-checked admin password.
-- BEFORE RUNNING: replace CHANGE_ME (near the bottom) with Juli's admin password.
-- Re-running this script is safe; it resets the password to whatever CHANGE_ME is replaced with.
set search_path = public, extensions;
create extension if not exists pgcrypto with schema extensions;

-- One row (id = 1) of settings every visitor reads: social links, payment handles,
-- shipping, welcome text. Anyone can read it; nobody can write it directly.
create table if not exists public.julis_settings (
  id         integer primary key default 1 check (id = 1),
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.julis_settings enable row level security;
drop policy if exists "julis_settings read"   on public.julis_settings;
drop policy if exists "julis_settings insert" on public.julis_settings;
drop policy if exists "julis_settings update" on public.julis_settings;
create policy "julis_settings read" on public.julis_settings for select to anon, authenticated using (true);
insert into public.julis_settings (id, data) values (1, '{}'::jsonb) on conflict (id) do nothing;

-- Admin password hash. RLS on with no policies + revoked grants: unreadable from the website.
create table if not exists public.julis_admin_secret (
  id            integer primary key default 1 check (id = 1),
  passcode_hash text not null
);
alter table public.julis_admin_secret enable row level security;
revoke all on public.julis_admin_secret from anon, authenticated;

create or replace function public.julis_check_passcode(p_passcode text)
returns boolean
language sql stable security definer set search_path = public, extensions
as $$
  select exists (
    select 1 from public.julis_admin_secret
    where id = 1 and passcode_hash = crypt(coalesce(p_passcode, ''), passcode_hash)
  );
$$;

-- Shallow-merges p_patch into the stored settings (only the keys sent are changed).
create or replace function public.julis_save_settings(p_passcode text, p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare result jsonb;
begin
  if not public.julis_check_passcode(p_passcode) then
    raise exception 'wrong passcode' using errcode = '28P01';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'settings patch must be a JSON object';
  end if;
  insert into public.julis_settings as s (id, data, updated_at)
  values (1, p_patch, now())
  on conflict (id) do update set data = s.data || excluded.data, updated_at = now()
  returning s.data into result;
  return result;
end;
$$;

create or replace function public.julis_change_passcode(p_old text, p_new text)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not public.julis_check_passcode(p_old) then
    raise exception 'wrong passcode' using errcode = '28P01';
  end if;
  if p_new is null or length(p_new) < 4 then
    raise exception 'new password must be at least 4 characters';
  end if;
  update public.julis_admin_secret set passcode_hash = crypt(p_new, gen_salt('bf')) where id = 1;
end;
$$;

revoke all on function public.julis_check_passcode(text)        from public;
revoke all on function public.julis_save_settings(text, jsonb)  from public;
revoke all on function public.julis_change_passcode(text, text) from public;
grant execute on function public.julis_check_passcode(text)        to anon, authenticated;
grant execute on function public.julis_save_settings(text, jsonb)  to anon, authenticated;
grant execute on function public.julis_change_passcode(text, text) to anon, authenticated;

-- Juli's admin password (replace CHANGE_ME before running):
insert into public.julis_admin_secret (id, passcode_hash)
values (1, crypt('CHANGE_ME', gen_salt('bf')))
on conflict (id) do update set passcode_hash = excluded.passcode_hash;
