-- Shared shop settings (social links, payment handles, shipping, welcome text)
-- so every visitor sees the same values. One row only (id = 1).
-- The admin password is NOT stored here: this table is readable by anyone.
create table if not exists public.julis_settings (
  id         integer primary key default 1 check (id = 1),
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.julis_settings enable row level security;

drop policy if exists "julis_settings read"   on public.julis_settings;
drop policy if exists "julis_settings insert" on public.julis_settings;
drop policy if exists "julis_settings update" on public.julis_settings;

create policy "julis_settings read"   on public.julis_settings for select to anon, authenticated using (true);
create policy "julis_settings insert" on public.julis_settings for insert to anon, authenticated with check (id = 1);
create policy "julis_settings update" on public.julis_settings for update to anon, authenticated using (id = 1) with check (id = 1);

insert into public.julis_settings (id, data) values (1, '{}'::jsonb) on conflict (id) do nothing;
