-- Juli's Studios: per-product reviews that only appear after Juli approves them.
-- Shoppers submit through julis_submit_review (always pending, rate limited).
-- Juli lists, approves and deletes through password-checked RPCs.
-- Safe to re-run.

alter table public.julis_reviews
  add column if not exists product_id integer references public.julis_products(id) on delete cascade;
alter table public.julis_reviews alter column approved set default false;
create index if not exists julis_reviews_product on public.julis_reviews (product_id) where approved;

alter table public.julis_reviews enable row level security;
drop policy if exists "Anyone can delete reviews" on public.julis_reviews;
drop policy if exists "Anyone can submit review"  on public.julis_reviews;
drop policy if exists "Anyone can update reviews" on public.julis_reviews;
drop policy if exists "Public reads approved reviews" on public.julis_reviews;
create policy "Public reads approved reviews" on public.julis_reviews
  for select using (approved = true);
revoke all on public.julis_reviews from anon, authenticated;
grant select on public.julis_reviews to anon, authenticated;

create table if not exists public.julis_review_attempts (
  client text not null,
  at     timestamptz not null default now()
);
create index if not exists julis_review_attempts_client_at on public.julis_review_attempts (client, at);
alter table public.julis_review_attempts enable row level security;
revoke all on public.julis_review_attempts from anon, authenticated;

-- Returns the new review id. Raises on invalid input or too many reviews from one client.
create or replace function public.julis_submit_review(
  p_product_id integer, p_name text, p_rating integer, p_message text)
returns bigint
language plpgsql volatile security definer set search_path = public
as $$
declare
  k text := coalesce(nullif(trim(split_part(
    coalesce(nullif(current_setting('request.headers', true), '')::json->>'x-forwarded-for', ''),
    ',', 1)), ''), 'unknown');
  n text := trim(coalesce(p_name, ''));
  m text := trim(coalesce(p_message, ''));
  new_id bigint;
begin
  if not exists (select 1 from public.julis_products where id = p_product_id) then
    raise exception 'product not found';
  end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception 'rating must be 1-5';
  end if;
  if char_length(n) < 1 or char_length(n) > 40 then
    raise exception 'name must be 1-40 characters';
  end if;
  if char_length(m) < 1 or char_length(m) > 500 then
    raise exception 'message must be 1-500 characters';
  end if;
  perform pg_advisory_xact_lock(hashtext('julis_review:' || k));
  if (select count(*) from public.julis_review_attempts
       where client = k and at > now() - interval '1 hour') >= 5 then
    raise exception 'too many reviews, try again later' using errcode = 'P0001';
  end if;
  insert into public.julis_review_attempts (client) values (k);
  delete from public.julis_review_attempts where at < now() - interval '1 day';
  insert into public.julis_reviews (product_id, name, rating, message, approved)
  values (p_product_id, n, p_rating, m, false)
  returning id into new_id;
  return new_id;
end;
$$;

-- All reviews (pending first), or null when the password is wrong or locked out.
create or replace function public.julis_admin_reviews(p_passcode text)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions
as $$
begin
  if not public.julis_check_passcode(p_passcode) then
    return null;
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(r) order by r.approved, r.created_at desc)
      from public.julis_reviews r), '[]'::jsonb);
end;
$$;

-- p_action: 'approve' or 'delete'. Returns false when the password is wrong or locked out.
create or replace function public.julis_moderate_review(p_passcode text, p_id bigint, p_action text)
returns boolean
language plpgsql volatile security definer set search_path = public, extensions
as $$
begin
  if p_action not in ('approve', 'delete') then
    raise exception 'action must be approve or delete';
  end if;
  if not public.julis_check_passcode(p_passcode) then
    return false;
  end if;
  if p_action = 'approve' then
    update public.julis_reviews set approved = true where id = p_id;
  else
    delete from public.julis_reviews where id = p_id;
  end if;
  return true;
end;
$$;

revoke all on function public.julis_submit_review(integer, text, integer, text) from public;
revoke all on function public.julis_admin_reviews(text)                         from public;
revoke all on function public.julis_moderate_review(text, bigint, text)         from public;
grant execute on function public.julis_submit_review(integer, text, integer, text) to anon, authenticated;
grant execute on function public.julis_admin_reviews(text)                         to anon, authenticated;
grant execute on function public.julis_moderate_review(text, bigint, text)         to anon, authenticated;
