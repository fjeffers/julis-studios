-- Juli's Studios: place an order and take its items off the shelf in one
-- transaction. Stock only changes when an order row is created, a tracked item
-- can't be oversold, and a retry can't deduct the same order twice. Safe to re-run.
-- p_order: {customer_name, phone, address, payment_method, items, subtotal, shipping, handling, total}
-- p_items: [{"id": 3, "quantity": 2}, ...]
drop function if exists public.julis_decrement_stock(jsonb);

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
    (customer_name, phone, address, payment_method, items, subtotal, shipping, handling, total)
  select r.customer_name, r.phone, r.address, r.payment_method, r.items,
         r.subtotal, r.shipping, r.handling, r.total
    from jsonb_to_record(p_order) as r(
      customer_name text, phone text, address text, payment_method text, items jsonb,
      subtotal numeric, shipping numeric, handling numeric, total numeric);

  for item in select * from jsonb_array_elements(p_items) loop
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
