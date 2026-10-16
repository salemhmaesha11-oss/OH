-- Grant only the table operations used by the app. Row-level security policies
-- continue to determine which rows each role may access.

grant usage on schema public to anon, authenticated, service_role;

grant select on public.products to anon, authenticated;
grant insert, update, delete on public.products to authenticated;

grant select, update on public.profiles to authenticated;
grant select on public.orders, public.order_items, public.sales, public.sale_items,
  public.inventory_movements to authenticated;

notify pgrst, 'reload schema';
