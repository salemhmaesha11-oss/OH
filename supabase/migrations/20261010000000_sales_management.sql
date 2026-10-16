alter table public.sales
  add column if not exists sale_number bigint generated always as identity,
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references public.profiles(id) on delete set null;

create unique index if not exists sales_sale_number_idx on public.sales(sale_number);

alter table public.sale_items
  add column if not exists returned_quantity integer not null default 0;

alter table public.sale_items
  drop constraint if exists sale_items_returned_quantity_check;
alter table public.sale_items
  add constraint sale_items_returned_quantity_check
  check (returned_quantity >= 0 and returned_quantity <= quantity);

alter table public.inventory_movements
  drop constraint if exists inventory_movements_movement_type_check;

alter table public.inventory_movements
  add constraint inventory_movements_movement_type_check
  check (movement_type in ('restock', 'order_fulfillment', 'sale', 'adjustment', 'sale_return', 'sale_edit'));

create table if not exists public.sale_adjustments (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales(id) on delete cascade,
  sale_item_id uuid references public.sale_items(id) on delete set null,
  actor_id uuid references public.profiles(id) on delete set null,
  adjustment_type text not null check (adjustment_type in ('return', 'edit')),
  details jsonb not null default '{}'::jsonb,
  note text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists sale_adjustments_sale_created_idx
  on public.sale_adjustments(sale_id, created_at desc);

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
grant select (id, name, category, icon, image_url, price, active) on public.products to anon, authenticated;
grant select on public.customer_products to anon, authenticated;
grant select on public.staff_products to authenticated;

alter table public.sale_adjustments enable row level security;
grant select on public.sale_adjustments to authenticated;

drop policy if exists "Staff read sales" on public.sales;
drop policy if exists "Staff read own sales; owners read all" on public.sales;
create policy "Staff read own sales; owners read all"
on public.sales for select to authenticated
using (
  public.current_profile_role() = 'owner'
  or (public.current_profile_role() = 'seller' and seller_id = (select auth.uid()))
);

drop policy if exists "Staff read sale items" on public.sale_items;
drop policy if exists "Staff read visible sale items" on public.sale_items;
create policy "Staff read visible sale items"
on public.sale_items for select to authenticated
using (
  exists (
    select 1 from public.sales s
    where s.id = sale_id
      and (
        public.current_profile_role() = 'owner'
        or (public.current_profile_role() = 'seller' and s.seller_id = (select auth.uid()))
      )
  )
);

drop policy if exists "Staff read visible sale adjustments" on public.sale_adjustments;
create policy "Staff read visible sale adjustments"
on public.sale_adjustments for select to authenticated
using (
  exists (
    select 1 from public.sales s
    where s.id = sale_id
      and (
        public.current_profile_role() = 'owner'
        or (public.current_profile_role() = 'seller' and s.seller_id = (select auth.uid()))
      )
  )
);

create or replace function public.restock_product(
  p_product_id uuid,
  p_quantity integer,
  p_note text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_product public.products%rowtype;
begin
  if public.current_profile_role() is distinct from 'owner' then
    raise exception 'Only owners can restock products';
  end if;
  if p_quantity is null or p_quantity < 1 then
    raise exception 'Restock quantity must be positive';
  end if;
  if nullif(trim(p_note), '') is null or length(trim(p_note)) > 500 then
    raise exception 'A restock note up to 500 characters is required';
  end if;

  select * into v_product
  from public.products
  where id = p_product_id and active
  for update;
  if not found then
    raise exception 'Product is unavailable';
  end if;

  update public.products
  set stock = stock + p_quantity
  where id = p_product_id
  returning * into v_product;

  insert into public.inventory_movements
    (product_id, product_name, actor_id, movement_type, quantity_delta, note)
  values
    (v_product.id, v_product.name, (select auth.uid()), 'restock', p_quantity, trim(p_note));

  return v_product.stock;
end;
$$;

create or replace function public.return_sale_item(
  p_sale_item_id uuid,
  p_quantity integer,
  p_note text default ''
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sale_id uuid;
  v_sale public.sales%rowtype;
  v_item public.sale_items%rowtype;
  v_product public.products%rowtype;
begin
  if coalesce(public.current_profile_role(), '') not in ('seller', 'owner') then
    raise exception 'Staff access is required';
  end if;
  if p_quantity is null or p_quantity < 1 then
    raise exception 'Return quantity must be positive';
  end if;
  if length(coalesce(p_note, '')) > 500 then
    raise exception 'Return note must be no longer than 500 characters';
  end if;

  select sale_id into v_sale_id
  from public.sale_items
  where id = p_sale_item_id;
  if not found then
    raise exception 'Sale item does not exist';
  end if;

  select * into v_sale
  from public.sales
  where id = v_sale_id
  for update;
  if not found or v_sale.archived_at is not null then
    raise exception 'Sale is unavailable or archived';
  end if;
  if public.current_profile_role() = 'seller' and v_sale.seller_id <> (select auth.uid()) then
    raise exception 'Sellers can only return their own sales';
  end if;
  if public.current_profile_role() = 'seller' and v_sale.created_at < now() - interval '24 hours' then
    raise exception 'Sales can only be changed within 24 hours';
  end if;

  select * into v_item
  from public.sale_items
  where id = p_sale_item_id and sale_id = v_sale.id
  for update;
  if not found or v_item.product_id is null
    or v_item.returned_quantity + p_quantity > v_item.quantity then
    raise exception 'Return quantity exceeds the unreturned quantity';
  end if;

  select * into v_product
  from public.products
  where id = v_item.product_id
  for update;
  if not found then
    raise exception 'Product no longer exists in inventory';
  end if;

  update public.products
  set stock = stock + p_quantity,
      total_sold = greatest(0, total_sold - p_quantity)
  where id = v_product.id;

  update public.sale_items
  set returned_quantity = returned_quantity + p_quantity
  where id = v_item.id;

  insert into public.inventory_movements
    (product_id, product_name, actor_id, movement_type, quantity_delta, note)
  values
    (v_product.id, v_item.product_name, (select auth.uid()), 'sale_return', p_quantity,
     coalesce(nullif(trim(p_note), ''), 'Return for sale ' || v_sale.sale_number::text));

  insert into public.sale_adjustments
    (sale_id, sale_item_id, actor_id, adjustment_type, details, note)
  values
    (v_sale.id, v_item.id, (select auth.uid()), 'return',
     jsonb_build_object('product_id', v_product.id, 'product_name', v_item.product_name, 'quantity', p_quantity),
     coalesce(trim(p_note), ''));
end;
$$;

create or replace function public.edit_sale_items(
  p_sale_id uuid,
  p_items jsonb,
  p_note text default ''
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sale public.sales%rowtype;
  v_product_id uuid;
  v_product public.products%rowtype;
  v_old_quantity integer;
  v_new_quantity integer;
  v_delta integer;
  v_unit_price numeric(12, 2);
  v_old_items jsonb;
  v_new_items jsonb;
  v_entry jsonb;
begin
  if coalesce(public.current_profile_role(), '') not in ('seller', 'owner') then
    raise exception 'Staff access is required';
  end if;
  if p_items is null or jsonb_typeof(p_items) is distinct from 'array'
    or jsonb_array_length(p_items) = 0 then
    raise exception 'An edited sale must contain at least one product';
  end if;
  if length(coalesce(p_note, '')) > 500 then
    raise exception 'Edit note must be no longer than 500 characters';
  end if;

  for v_entry in select value from jsonb_array_elements(p_items)
  loop
    if (v_entry ->> 'product_id') is null
      or (v_entry ->> 'quantity') !~ '^[1-9][0-9]*$' then
      raise exception 'Each sale item requires a product and positive integer quantity';
    end if;
  end loop;

  if (select count(*) from jsonb_array_elements(p_items)) <>
     (select count(distinct (value ->> 'product_id')) from jsonb_array_elements(p_items)) then
    raise exception 'A product may only appear once in an edited sale';
  end if;

  select * into v_sale
  from public.sales
  where id = p_sale_id
  for update;
  if not found or v_sale.archived_at is not null then
    raise exception 'Sale is unavailable or archived';
  end if;
  if public.current_profile_role() = 'seller' and v_sale.seller_id <> (select auth.uid()) then
    raise exception 'Sellers can only edit their own sales';
  end if;
  if public.current_profile_role() = 'seller' and v_sale.created_at < now() - interval '24 hours' then
    raise exception 'Sales can only be changed within 24 hours';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'sale_item_id', id,
    'product_id', product_id,
    'product_name', product_name,
    'quantity', quantity,
    'returned_quantity', returned_quantity,
    'unit_price', unit_price
  )), '[]'::jsonb)
  into v_old_items
  from public.sale_items
  where sale_id = v_sale.id;
  v_new_items := p_items;

  if exists (
    select 1 from public.sale_items
    where sale_id = v_sale.id and product_id is null and returned_quantity < quantity
  ) then
    raise exception 'A product in this sale is no longer available';
  end if;

  for v_product_id in
    select product_id from (
      select si.product_id
      from public.sale_items si
      where si.sale_id = v_sale.id and si.product_id is not null and si.returned_quantity < si.quantity
      union
      select (entry.value ->> 'product_id')::uuid
      from jsonb_array_elements(p_items) entry
    ) product_ids
    order by product_id
  loop
    select coalesce(sum(quantity - returned_quantity), 0)::integer,
           coalesce(sum((quantity - returned_quantity) * unit_price) /
             nullif(sum(quantity - returned_quantity), 0), 0)::numeric(12, 2)
    into v_old_quantity, v_unit_price
    from public.sale_items
    where sale_id = v_sale.id and product_id = v_product_id;

    select coalesce(sum((entry.value ->> 'quantity')::integer), 0)::integer
    into v_new_quantity
    from jsonb_array_elements(p_items) entry
    where (entry.value ->> 'product_id')::uuid = v_product_id;

    v_delta := v_new_quantity - v_old_quantity;
    select * into v_product
    from public.products
    where id = v_product_id and active
    for update;
    if not found then
      raise exception 'Product is unavailable';
    end if;

    if v_delta > 0 and v_product.stock < v_delta then
      raise exception 'Insufficient stock for %', v_product.name;
    end if;

    if v_delta <> 0 then
      update public.products
      set stock = stock - v_delta,
          total_sold = greatest(0, total_sold + v_delta)
      where id = v_product.id;

      insert into public.inventory_movements
        (product_id, product_name, actor_id, movement_type, quantity_delta, note)
      values
        (v_product.id, v_product.name, (select auth.uid()), 'sale_edit', -v_delta,
         coalesce(nullif(trim(p_note), ''), 'Edit sale ' || v_sale.sale_number::text));
    end if;

    update public.sale_items
    set returned_quantity = quantity
    where sale_id = v_sale.id and product_id = v_product_id
      and returned_quantity < quantity;

    if v_new_quantity > 0 then
      if v_old_quantity = 0 then v_unit_price := v_product.price; end if;

      insert into public.sale_items
        (sale_id, product_id, product_name, quantity, returned_quantity, unit_price)
      values
        (v_sale.id, v_product.id, v_product.name, v_new_quantity, 0, v_unit_price);
    end if;
  end loop;

  insert into public.sale_adjustments
    (sale_id, actor_id, adjustment_type, details, note)
  values
    (v_sale.id, (select auth.uid()), 'edit',
     jsonb_build_object('before', v_old_items, 'after', v_new_items), coalesce(trim(p_note), ''));
end;
$$;

create or replace function public.archive_sale(p_sale_id uuid, p_archived boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.current_profile_role() is distinct from 'owner' then
    raise exception 'Only owners can archive sales';
  end if;
  if p_archived is null then
    raise exception 'Archive state is required';
  end if;

  update public.sales
  set archived_at = case when p_archived then now() else null end,
      archived_by = case when p_archived then (select auth.uid()) else null end
  where id = p_sale_id;
  if not found then
    raise exception 'Sale does not exist';
  end if;
end;
$$;

revoke all on function public.restock_product(uuid, integer, text) from public, anon;
grant execute on function public.restock_product(uuid, integer, text) to authenticated;
revoke all on function public.return_sale_item(uuid, integer, text) from public, anon;
grant execute on function public.return_sale_item(uuid, integer, text) to authenticated;
revoke all on function public.edit_sale_items(uuid, jsonb, text) from public, anon;
grant execute on function public.edit_sale_items(uuid, jsonb, text) to authenticated;
revoke all on function public.archive_sale(uuid, boolean) from public, anon;
grant execute on function public.archive_sale(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
