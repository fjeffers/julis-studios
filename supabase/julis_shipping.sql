-- Juli's Studios: live shipping rates. Adds a per-item weight and records the
-- shipping service the shopper picked. Safe to re-run.
alter table public.julis_products
  add column if not exists weight_oz numeric not null default 0 check (weight_oz >= 0 and weight_oz <= 1120),
  add column if not exists package_size text not null default '' check (package_size in ('', 'envelope', 'small', 'medium'));
alter table public.julis_orders
  add column if not exists shipping_service text not null default '';

create or replace function public.julis_place_order(p_order jsonb, p_items jsonb)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  item jsonb;
  qty  int;
begin
  if p_order is null or jsonb_typeof(p_order) <> 'object' then
    raise exception 'order must be a JSON object';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'items must be a non-empty JSON array';
  end if;

  insert into public.julis_orders
    (customer_name, phone, address, payment_method, items, subtotal, shipping, handling, total, shipping_service)
  select r.customer_name, r.phone, r.address, r.payment_method, r.items,
         r.subtotal, r.shipping, r.handling, r.total, left(coalesce(r.shipping_service, ''), 80)
    from jsonb_to_record(p_order) as r(
      customer_name text, phone text, address text, payment_method text, items jsonb,
      subtotal numeric, shipping numeric, handling numeric, total numeric, shipping_service text);

  -- Lock products in id order so overlapping checkouts can't deadlock.
  for item in select value from jsonb_array_elements(p_items) order by (value->>'id')::bigint loop
    qty := (item->>'quantity')::int;
    if qty is null or qty < 1 or qty > 100 then
      raise exception 'invalid quantity';
    end if;
    perform 1 from public.julis_products where id = (item->>'id')::bigint;
    if not found then
      raise exception 'out of stock' using errcode = 'P0001';
    end if;
    update public.julis_products
       set stock_quantity = stock_quantity - qty
     where id = (item->>'id')::bigint
       and track_stock is distinct from false
       and coalesce(stock_quantity, 0) >= qty;
    if not found and exists (
      select 1 from public.julis_products
       where id = (item->>'id')::bigint and track_stock is distinct from false
    ) then
      raise exception 'out of stock' using errcode = 'P0001';
    end if;
  end loop;
end;
$$;

revoke all on function public.julis_place_order(jsonb, jsonb) from public;
grant execute on function public.julis_place_order(jsonb, jsonb) to anon, authenticated;
