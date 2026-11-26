-- Juli's Studios: take sold items off the shelf atomically, so two shoppers
-- (or a stale page) can't write a wrong stock count. Safe to re-run.
-- p_items: [{"id": 3, "quantity": 2}, ...]
create or replace function public.julis_decrement_stock(p_items jsonb)
returns void
language plpgsql security definer set search_path = public
as $$
declare item jsonb;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'items must be a JSON array';
  end if;
  for item in select * from jsonb_array_elements(p_items) loop
    update public.julis_products
       set stock_quantity = greatest(0, coalesce(stock_quantity, 0) - greatest(0, (item->>'quantity')::int))
     where id = (item->>'id')::bigint
       and track_stock is distinct from false;
  end loop;
end;
$$;

revoke all on function public.julis_decrement_stock(jsonb) from public;
grant execute on function public.julis_decrement_stock(jsonb) to anon, authenticated;
