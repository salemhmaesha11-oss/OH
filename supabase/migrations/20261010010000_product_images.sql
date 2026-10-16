alter table public.products
  add column if not exists image_url text;

create or replace view public.customer_products
with (security_barrier = true)
as
select id, name, category, icon, price, (stock > 0) as in_stock, image_url
from public.products
where active;

create or replace view public.staff_products
with (security_barrier = true)
as
select id, name, category, icon, price, stock, total_sold, image_url
from public.products
where active and public.current_profile_role() in ('seller', 'owner');

revoke select on public.products from anon, authenticated;
grant select (id, name, category, icon, image_url, price, active)
  on public.products to anon, authenticated;
grant select on public.customer_products to anon, authenticated;
grant select on public.staff_products to authenticated;
