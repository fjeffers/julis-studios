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
-- true while the temporary default password is still in place.
alter table public.julis_admin_secret add column if not exists must_change boolean not null default true;
alter table public.julis_admin_secret enable row level security;
revoke all on public.julis_admin_secret from anon, authenticated;

-- Failed password tries per client; 5 failures lock that client out for 15 minutes.
create table if not exists public.julis_passcode_attempts (
  client text not null,
  at     timestamptz not null default now()
);
create index if not exists julis_passcode_attempts_client_at on public.julis_passcode_attempts (client, at);
alter table public.julis_passcode_attempts enable row level security;
revoke all on public.julis_passcode_attempts from anon, authenticated;

-- Never raises, so a recorded failure is not rolled back with the caller's transaction.
create or replace function public.julis_check_passcode(p_passcode text)
returns boolean
language plpgsql volatile security definer set search_path = public, extensions
as $$
declare
  k text := coalesce(nullif(trim(split_part(
    coalesce(nullif(current_setting('request.headers', true), '')::json->>'x-forwarded-for', ''),
    ',', 1)), ''), 'unknown');
  fails int;
begin
  -- Serialize tries per client so overlapping requests can't share one failure count.
  perform pg_advisory_xact_lock(hashtext('julis_passcode:' || k));
  select count(*) into fails from public.julis_passcode_attempts
   where client = k and at > now() - interval '15 minutes';
  if fails >= 5 then
    return false;
  end if;
  if exists (
    select 1 from public.julis_admin_secret
    where id = 1 and passcode_hash = crypt(coalesce(p_passcode, ''), passcode_hash)
  ) then
    delete from public.julis_passcode_attempts where client = k;
    return true;
  end if;
  insert into public.julis_passcode_attempts (client) values (k);
  delete from public.julis_passcode_attempts where at < now() - interval '1 day';
  return false;
end;
$$;

-- Shallow-merges p_patch into the stored settings (only the keys sent are changed).
-- Returns the merged settings, or null when the password is wrong or locked out.
create or replace function public.julis_save_settings(p_passcode text, p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare result jsonb;
begin
  if not public.julis_check_passcode(p_passcode) then
    return null;
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

-- Returns false when the current password is wrong or locked out.
drop function if exists public.julis_change_passcode(text, text);
create or replace function public.julis_change_passcode(p_old text, p_new text)
returns boolean
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not public.julis_check_passcode(p_old) then
    return false;
  end if;
  if p_new is null or length(p_new) < 8 then
    raise exception 'new password must be at least 8 characters';
  end if;
  if p_new = p_old then
    raise exception 'new password must be different';
  end if;
  update public.julis_admin_secret
     set passcode_hash = crypt(p_new, gen_salt('bf')), must_change = false
   where id = 1;
  return true;
end;
$$;

-- True while Juli is still on the temporary password; the site then makes her pick her own.
create or replace function public.julis_password_needs_reset()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select must_change from public.julis_admin_secret where id = 1), false);
$$;

revoke all on function public.julis_check_passcode(text)        from public;
revoke all on function public.julis_save_settings(text, jsonb)  from public;
revoke all on function public.julis_change_passcode(text, text) from public;
grant execute on function public.julis_check_passcode(text)        to anon, authenticated;
grant execute on function public.julis_save_settings(text, jsonb)  to anon, authenticated;
grant execute on function public.julis_change_passcode(text, text) to anon, authenticated;
revoke all on function public.julis_password_needs_reset()       from public;
grant execute on function public.julis_password_needs_reset()       to anon, authenticated;

-- Temporary default password: replace CHANGE_ME before running (never commit the real value —
-- this repo is public). Juli must change it in Settings the first time she signs in.
insert into public.julis_admin_secret (id, passcode_hash, must_change)
values (1, crypt('CHANGE_ME', gen_salt('bf')), true)
on conflict (id) do update set passcode_hash = excluded.passcode_hash, must_change = true;
