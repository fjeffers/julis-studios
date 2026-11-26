-- Collections, extra photos, video links and shopper choices (e.g. nail size/shape).
-- Safe to re-run: only adds columns with defaults, existing products keep working.
alter table public.julis_products
  add column if not exists collection text  not null default '',
  add column if not exists images     jsonb not null default '[]'::jsonb,
  add column if not exists video_url  text  not null default '',
  add column if not exists options    jsonb not null default '[]'::jsonb;
