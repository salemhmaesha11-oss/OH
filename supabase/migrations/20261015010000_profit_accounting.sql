begin;

alter table public.products
  add column if not exists margin_percent numeric(5, 2)
    check (margin_percent is null or margin_percent between 0 and 99.99);

create table if not exists public.accounting_settings (
  id boolean primary key default true check (id),
  default_margin_percent numeric(5, 2) not null default 10
    check (default_margin_percent between 0 and 99.99),
  updated_at timestamptz not null default now()
);

insert into public.accounting_settings (id, default_margin_percent)
values (true, 10)
on conflict (id) do nothing;

create table if not exists public.inventory_batches (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  quantity_received integer not null check (quantity_received > 0),
  quantity_remaining integer not null check (
    quantity_remaining >= 0 and quantity_remaining <= quantity_received
  ),
  unit_cost numeric(12, 2) check (unit_cost is null or unit_cost >= 0),
  created_at timestamptz not null default now()
);

create index if not exists inventory_batches_fifo_idx
  on public.inventory_batches(product_id, created_at, id)
  where quantity_remaining > 0;

insert into public.inventory_batches (product_id, quantity_received, quantity_remaining)
select id, stock, stock
from public.products
where stock > 0
  and not exists (
    select 1 from public.inventory_batches b where b.product_id = products.id
  );

create table if not exists public.inventory_cost_allocations (
  id uuid primary key default gen_random_uuid(),
  source_type text not null check (source_type in ('sale', 'order')),
  source_item_id uuid not null,
  cost_total numeric(14, 2) check (cost_total is null or cost_total >= 0),
  cost_complete boolean not null default false,
  created_at timestamptz not null default now(),
  unique (source_type, source_item_id),
  check (cost_complete = (cost_total is not null))
);

create table if not exists public.operating_expenses (
  id uuid primary key default gen_random_uuid(),
  category text not null check (length(trim(category)) between 1 and 80),
  description text not null check (length(trim(description)) between 1 and 300),
  amount numeric(12, 2) not null check (amount > 0),
  expense_date date not null default current_date,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists operating_expenses_date_idx
  on public.operating_expenses(expense_date desc, created_at desc);

alter table public.inventory_batches enable row level security;
alter table public.inventory_cost_allocations enable row level security;
alter table public.accounting_settings enable row level security;
alter table public.operating_expenses enable row level security;

grant select on public.operating_expenses to authenticated;
grant insert (category, description, amount, expense_date, created_by),
  update (category, description, amount, expense_date),
  delete on public.operating_expenses to authenticated;

create policy "Owners manage operating expenses"
on public.operating_expenses for all to authenticated
using (public.current_profile_role() = 'owner')
with check (public.current_profile_role() = 'owner');

create or replace function public.touch_operating_expense()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger operating_expenses_touch_updated_at
before update on public.operating_expenses
for each row execute function public.touch_operating_expense();

create policy "Owners read accounting settings"
on public.accounting_settings for select to authenticated
using (public.current_profile_role() = 'owner');

revoke all on public.inventory_batches, public.inventory_cost_allocations,
  public.accounting_settings from anon, authenticated;

create or replace function public.consume_inventory_batches(
  p_product_id uuid,
  p_quantity integer
)
returns table(cost_amount numeric, cost_known boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch public.inventory_batches%rowtype;
  v_take integer;
  v_remaining integer := p_quantity;
  v_total numeric(14, 2) := 0;
  v_known boolean := true;
begin
  if p_quantity is null or p_quantity < 1 then
    raise exception 'Consumed quantity must be positive';
  end if;

  if coalesce((
    select sum(b.quantity_remaining)
    from public.inventory_batches b
    where b.product_id = p_product_id
  ), 0) < p_quantity then
    raise exception 'Inventory cost batches do not match available stock; reconcile inventory before selling';
  end if;

  for v_batch in
    select b.*
    from public.inventory_batches b
    where b.product_id = p_product_id and b.quantity_remaining > 0
    order by b.created_at, b.id
    for update
  loop
    exit when v_remaining = 0;
    v_take := least(v_remaining, v_batch.quantity_remaining);
    update public.inventory_batches
    set quantity_remaining = quantity_remaining - v_take
    where id = v_batch.id;

    if v_batch.unit_cost is null then
      v_known := false;
    else
      v_total := v_total + v_batch.unit_cost * v_take;
    end if;
    v_remaining := v_remaining - v_take;
  end loop;

  return query select case when v_known then v_total else null end, v_known;
end;
$$;

create or replace function public.refresh_product_sale_price(p_product_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_product public.products%rowtype;
  v_cost_total numeric;
  v_quantity integer;
  v_unknown integer;
  v_margin numeric(5, 2);
  v_price numeric;
begin
  select * into v_product
  from public.products
  where id = p_product_id
  for update;
  if not found or v_product.stock < 1 then
    return;
  end if;

  select coalesce(sum(b.quantity_remaining * b.unit_cost), 0),
         coalesce(sum(b.quantity_remaining), 0)::integer,
         count(*) filter (where b.quantity_remaining > 0 and b.unit_cost is null)::integer
  into v_cost_total, v_quantity, v_unknown
  from public.inventory_batches b
  where b.product_id = p_product_id and b.quantity_remaining > 0;

  if v_quantity <> v_product.stock or v_unknown > 0 or v_quantity = 0 then
    return;
  end if;

  select coalesce(v_product.margin_percent, s.default_margin_percent)
  into v_margin
  from public.accounting_settings s
  where s.id = true;

  v_price := round((v_cost_total / v_quantity) / (1 - v_margin / 100), 2);
  if v_price > 9999999999.99 then
    raise exception 'Calculated sale price exceeds the supported product price limit';
  end if;

  update public.products
  set price = v_price,
      updated_at = now()
  where id = p_product_id;
end;
$$;

drop function if exists public.restock_product(uuid, integer, text);

create or replace function public.restock_product(
  p_product_id uuid,
  p_quantity integer,
  p_unit_cost numeric
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
  if p_unit_cost is null or p_unit_cost < 0 or p_unit_cost > 9999999999.99 then
    raise exception 'Enter a valid unit purchase cost';
  end if;

  select * into v_product
  from public.products
  where id = p_product_id and active
  for update;
  if not found then
    raise exception 'Product is unavailable';
  end if;

  insert into public.inventory_batches
    (product_id, quantity_received, quantity_remaining, unit_cost)
  values (v_product.id, p_quantity, p_quantity, round(p_unit_cost, 2));

  update public.products
  set stock = stock + p_quantity, updated_at = now()
  where id = p_product_id
  returning * into v_product;

  insert into public.inventory_movements
    (product_id, product_name, actor_id, movement_type, quantity_delta, note)
  values
    (v_product.id, v_product.name, (select auth.uid()), 'restock', p_quantity,
     'Restock: ' || p_quantity::text || ' units at unit cost ' || round(p_unit_cost, 2)::text);

  perform public.refresh_product_sale_price(v_product.id);
  return v_product.stock;
end;
$$;

create or replace function public.set_default_profit_margin(p_margin_percent numeric)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_product_id uuid;
begin
  if public.current_profile_role() is distinct from 'owner' then
    raise exception 'Only owners can change profit margins';
  end if;
  if p_margin_percent is null or p_margin_percent < 0 or p_margin_percent > 99.99 then
    raise exception 'Profit margin must be between 0 and 99.99 percent';
  end if;

  update public.accounting_settings
  set default_margin_percent = round(p_margin_percent, 2), updated_at = now()
  where id = true;

  for v_product_id in
    select id from public.products where active and margin_percent is null order by id
  loop
    perform public.refresh_product_sale_price(v_product_id);
  end loop;
end;
$$;

create or replace function public.set_product_profit_margin(
  p_product_id uuid,
  p_margin_percent numeric
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.current_profile_role() is distinct from 'owner' then
    raise exception 'Only owners can change profit margins';
  end if;
  if p_margin_percent is not null
    and (p_margin_percent < 0 or p_margin_percent > 99.99) then
    raise exception 'Profit margin must be between 0 and 99.99 percent';
  end if;

  update public.products
  set margin_percent = round(p_margin_percent, 2), updated_at = now()
  where id = p_product_id and active;
  if not found then
    raise exception 'Product is unavailable';
  end if;

  perform public.refresh_product_sale_price(p_product_id);
end;
$$;

create or replace function public.set_opening_inventory_unit_cost(
  p_product_id uuid,
  p_unit_cost numeric
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated integer;
  v_missing integer;
  v_stock integer;
begin
  if public.current_profile_role() is distinct from 'owner' then
    raise exception 'Only owners can set opening inventory cost';
  end if;
  if p_unit_cost is null or p_unit_cost < 0 or p_unit_cost > 9999999999.99 then
    raise exception 'Enter a valid unit purchase cost';
  end if;

  select stock into v_stock
  from public.products
  where id = p_product_id and active
  for update;
  if not found then
    raise exception 'Product is unavailable';
  end if;

  select v_stock - coalesce(sum(quantity_remaining), 0)::integer
  into v_missing
  from public.inventory_batches
  where product_id = p_product_id;
  if v_missing < 0 then
    raise exception 'Inventory batches exceed product stock; reconcile inventory before setting cost';
  end if;

  update public.inventory_batches
  set unit_cost = round(p_unit_cost, 2)
  where product_id = p_product_id
    and quantity_remaining > 0
    and unit_cost is null;
  get diagnostics v_updated = row_count;
  if v_missing > 0 then
    insert into public.inventory_batches
      (product_id, quantity_received, quantity_remaining, unit_cost)
    values (p_product_id, v_missing, v_missing, round(p_unit_cost, 2));
    v_updated := v_updated + v_missing;
  end if;
  if v_updated = 0 then
    raise exception 'No uncosted opening inventory remains for this product';
  end if;

  perform public.refresh_product_sale_price(p_product_id);
  return v_updated;
end;
$$;

create or replace function public.capture_inventory_cost(
  p_source_type text,
  p_source_item_id uuid,
  p_product_id uuid,
  p_quantity integer
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cost numeric;
  v_known boolean;
begin
  select c.cost_amount, c.cost_known
  into v_cost, v_known
  from public.consume_inventory_batches(p_product_id, p_quantity) c;

  insert into public.inventory_cost_allocations
    (source_type, source_item_id, cost_total, cost_complete)
  values (p_source_type, p_source_item_id, v_cost, v_known)
  on conflict (source_type, source_item_id) do update
  set cost_total = excluded.cost_total, cost_complete = excluded.cost_complete;
end;
$$;

create or replace function public.complete_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_item public.order_items%rowtype;
  v_product public.products%rowtype;
begin
  if coalesce(public.current_profile_role(), '') not in ('seller', 'owner') then
    raise exception 'Only staff can complete an order';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found or v_order.status not in ('pending', 'preparing') then
    raise exception 'Order does not exist or is not awaiting fulfillment';
  end if;
  if not exists (select 1 from public.order_items where order_id = p_order_id) then
    raise exception 'An empty order cannot be completed';
  end if;

  for v_item in select * from public.order_items where order_id = p_order_id
  loop
    if v_item.product_id is null then
      raise exception 'Product % is no longer available', v_item.product_name;
    end if;

    select * into v_product
    from public.products
    where id = v_item.product_id and active
    for update;
    if not found or v_product.stock < v_item.quantity then
      raise exception 'Insufficient stock for %', v_item.product_name;
    end if;

    perform public.capture_inventory_cost('order', v_item.id, v_product.id, v_item.quantity);
    update public.products
    set stock = stock - v_item.quantity,
        total_sold = total_sold + v_item.quantity,
        updated_at = now()
    where id = v_product.id;

    insert into public.inventory_movements
      (product_id, product_name, actor_id, movement_type, quantity_delta, note)
    values
      (v_product.id, v_item.product_name, (select auth.uid()),
       'order_fulfillment', -v_item.quantity, 'Order ' || v_order.order_number);

    perform public.refresh_product_sale_price(v_product.id);
  end loop;

  update public.orders
  set status = 'ready', ready_at = now()
  where id = p_order_id;
end;
$$;

create or replace function public.record_daily_sales(p_items jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sale_id uuid;
  v_entry jsonb;
  v_product public.products%rowtype;
  v_quantity integer;
  v_sale_item_id uuid;
begin
  if coalesce(public.current_profile_role(), '') not in ('seller', 'owner') then
    raise exception 'Only staff can record sales';
  end if;
  if p_items is null or jsonb_typeof(p_items) is distinct from 'array'
    or jsonb_array_length(p_items) = 0 then
    raise exception 'At least one sale item is required';
  end if;

  insert into public.sales (seller_id)
  values ((select auth.uid()))
  returning id into v_sale_id;

  for v_entry in select value from jsonb_array_elements(p_items)
  loop
    if (v_entry ->> 'product_id') is null
      or (v_entry ->> 'quantity') !~ '^[1-9][0-9]*$' then
      raise exception 'Each sale item requires a product and positive integer quantity';
    end if;

    v_quantity := (v_entry ->> 'quantity')::integer;
    select * into v_product
    from public.products
    where id = (v_entry ->> 'product_id')::uuid and active
    for update;
    if not found or v_product.stock < v_quantity then
      raise exception 'Product not found or insufficient stock';
    end if;

    insert into public.sale_items
      (sale_id, product_id, product_name, quantity, unit_price)
    values (v_sale_id, v_product.id, v_product.name, v_quantity, v_product.price)
    returning id into v_sale_item_id;

    perform public.capture_inventory_cost('sale', v_sale_item_id, v_product.id, v_quantity);
    update public.products
    set stock = stock - v_quantity,
        total_sold = total_sold + v_quantity,
        updated_at = now()
    where id = v_product.id;

    insert into public.inventory_movements
      (product_id, product_name, actor_id, movement_type, quantity_delta, note)
    values
      (v_product.id, v_product.name, (select auth.uid()),
       'sale', -v_quantity, 'Sale ' || v_sale_id::text);

    perform public.refresh_product_sale_price(v_product.id);
  end loop;
  return v_sale_id;
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
  v_cost numeric;
  v_complete boolean;
  v_return_unit_cost numeric;
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

  select sale_id into v_sale_id from public.sale_items where id = p_sale_item_id;
  if not found then raise exception 'Sale item does not exist'; end if;

  select * into v_sale from public.sales where id = v_sale_id for update;
  if not found or v_sale.archived_at is not null then
    raise exception 'Sale is unavailable or archived';
  end if;
  if public.current_profile_role() = 'seller' and v_sale.seller_id <> (select auth.uid()) then
    raise exception 'Sellers can only return their own sales';
  end if;
  if public.current_profile_role() = 'seller' and v_sale.created_at < now() - interval '48 hours' then
    raise exception 'Sellers can only return sales within 48 hours';
  end if;

  select * into v_item
  from public.sale_items
  where id = p_sale_item_id and sale_id = v_sale.id
  for update;
  if not found or v_item.product_id is null
    or v_item.returned_quantity + p_quantity > v_item.quantity then
    raise exception 'Return quantity exceeds the unreturned quantity';
  end if;

  select a.cost_total, a.cost_complete into v_cost, v_complete
  from public.inventory_cost_allocations a
  where a.source_type = 'sale' and a.source_item_id = v_item.id;
  v_return_unit_cost := case
    when v_complete then v_cost / v_item.quantity
    else null
  end;

  select * into v_product
  from public.products
  where id = v_item.product_id
  for update;
  if not found then raise exception 'Product no longer exists in inventory'; end if;

  insert into public.inventory_batches
    (product_id, quantity_received, quantity_remaining, unit_cost)
  values (v_product.id, p_quantity, p_quantity, v_return_unit_cost);

  update public.products
  set stock = stock + p_quantity,
      total_sold = greatest(0, total_sold - p_quantity),
      updated_at = now()
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

  perform public.refresh_product_sale_price(v_product.id);
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
  v_old_cost numeric(14, 2);
  v_old_known boolean;
  v_delta_cost numeric(14, 2);
  v_delta_known boolean;
  v_new_cost numeric(14, 2);
  v_new_known boolean;
  v_old_items jsonb;
  v_new_items jsonb;
  v_entry jsonb;
  v_sale_item_id uuid;
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

  select * into v_sale from public.sales where id = p_sale_id for update;
  if not found or v_sale.archived_at is not null then
    raise exception 'Sale is unavailable or archived';
  end if;
  if public.current_profile_role() = 'seller' and v_sale.seller_id <> (select auth.uid()) then
    raise exception 'Sellers can only edit their own sales';
  end if;
  if public.current_profile_role() = 'seller' and v_sale.created_at < now() - interval '48 hours' then
    raise exception 'Sellers can only edit sales within 48 hours';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'sale_item_id', si.id, 'product_id', si.product_id, 'product_name', si.product_name,
    'quantity', si.quantity, 'returned_quantity', si.returned_quantity, 'unit_price', si.unit_price,
    'cost_total', a.cost_total, 'cost_complete', a.cost_complete
  )), '[]'::jsonb)
  into v_old_items
  from public.sale_items si
  left join public.inventory_cost_allocations a
    on a.source_type = 'sale' and a.source_item_id = si.id
  where si.sale_id = v_sale.id;
  v_new_items := p_items;

  if exists (
    select 1 from public.sale_items
    where sale_id = v_sale.id and product_id is null and returned_quantity < quantity
  ) then
    raise exception 'A product in this sale is no longer available';
  end if;

  for v_product_id in
    select product_id from (
      select si.product_id from public.sale_items si
      where si.sale_id = v_sale.id and si.product_id is not null and si.returned_quantity < si.quantity
      union
      select (entry.value ->> 'product_id')::uuid from jsonb_array_elements(p_items) entry
    ) product_ids
    order by product_id
  loop
    select coalesce(sum(si.quantity - si.returned_quantity), 0)::integer,
           coalesce(sum((si.quantity - si.returned_quantity) * si.unit_price) /
             nullif(sum(si.quantity - si.returned_quantity), 0), 0)::numeric(12, 2),
           coalesce(bool_and(coalesce(a.cost_complete, false)), false),
           coalesce(sum(a.cost_total * (si.quantity - si.returned_quantity) / nullif(si.quantity, 0))
             filter (where a.cost_complete), 0)::numeric(14, 2)
    into v_old_quantity, v_unit_price, v_old_known, v_old_cost
    from public.sale_items si
    left join public.inventory_cost_allocations a
      on a.source_type = 'sale' and a.source_item_id = si.id
    where si.sale_id = v_sale.id and si.product_id = v_product_id
      and si.quantity > si.returned_quantity;

    select coalesce(sum((entry.value ->> 'quantity')::integer), 0)::integer
    into v_new_quantity
    from jsonb_array_elements(p_items) entry
    where (entry.value ->> 'product_id')::uuid = v_product_id;

    v_delta := v_new_quantity - v_old_quantity;
    select * into v_product
    from public.products where id = v_product_id and active for update;
    if not found then raise exception 'Product is unavailable'; end if;
    if v_delta > 0 and v_product.stock < v_delta then
      raise exception 'Insufficient stock for %', v_product.name;
    end if;

    v_new_cost := v_old_cost;
    v_new_known := v_old_known;
    if v_delta > 0 then
      select c.cost_amount, c.cost_known into v_delta_cost, v_delta_known
      from public.consume_inventory_batches(v_product_id, v_delta) c;
      v_new_known := (v_old_quantity = 0 or v_old_known) and v_delta_known;
      if v_new_known then v_new_cost := v_old_cost + v_delta_cost; else v_new_cost := null; end if;
    elsif v_delta < 0 then
      v_new_known := v_old_known;
      if v_old_known and v_old_quantity > 0 then
        v_new_cost := round(v_old_cost * v_new_quantity / v_old_quantity, 2);
        insert into public.inventory_batches
          (product_id, quantity_received, quantity_remaining, unit_cost)
        values (v_product_id, -v_delta, -v_delta, v_old_cost / v_old_quantity);
      else
        v_new_cost := null;
        insert into public.inventory_batches
          (product_id, quantity_received, quantity_remaining, unit_cost)
        values (v_product_id, -v_delta, -v_delta, null);
      end if;
    end if;

    if v_delta <> 0 then
      update public.products
      set stock = stock - v_delta,
          total_sold = greatest(0, total_sold + v_delta),
          updated_at = now()
      where id = v_product_id;
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
      values (v_sale.id, v_product.id, v_product.name, v_new_quantity, 0, v_unit_price)
      returning id into v_sale_item_id;

      if v_new_known then
        insert into public.inventory_cost_allocations
          (source_type, source_item_id, cost_total, cost_complete)
        values ('sale', v_sale_item_id, v_new_cost, true);
      else
        insert into public.inventory_cost_allocations
          (source_type, source_item_id, cost_total, cost_complete)
        values ('sale', v_sale_item_id, null, false);
      end if;
    end if;

    perform public.refresh_product_sale_price(v_product_id);
  end loop;

  insert into public.sale_adjustments
    (sale_id, actor_id, adjustment_type, details, note)
  values
    (v_sale.id, (select auth.uid()), 'edit',
     jsonb_build_object('before', v_old_items, 'after', v_new_items), coalesce(trim(p_note), ''));
end;
$$;

create or replace function public.accounting_report(
  p_from date,
  p_to date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_margin numeric(5, 2);
  v_revenue numeric(14, 2);
  v_cost numeric(14, 2);
  v_expenses numeric(14, 2);
  v_unknown_items integer;
  v_products jsonb;
  v_expense_rows jsonb;
begin
  if public.current_profile_role() is distinct from 'owner' then
    raise exception 'Only owners can view accounting reports';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'Enter a valid accounting report date range';
  end if;

  select default_margin_percent into v_margin
  from public.accounting_settings where id = true;

  with transactions as (
    select si.product_id, si.quantity - si.returned_quantity as quantity,
      si.unit_price * (si.quantity - si.returned_quantity) as revenue,
      case when a.cost_complete
        then a.cost_total * (si.quantity - si.returned_quantity) / nullif(si.quantity, 0)
        else 0 end as cost,
      case when a.cost_complete then 0 else si.quantity - si.returned_quantity end as unknown_quantity
    from public.sale_items si
    join public.sales s on s.id = si.sale_id
    left join public.inventory_cost_allocations a
      on a.source_type = 'sale' and a.source_item_id = si.id
    where s.created_at::date between p_from and p_to
    union all
    select oi.product_id, oi.quantity, oi.unit_price * oi.quantity,
      case when a.cost_complete then a.cost_total else 0 end,
      case when a.cost_complete then 0 else oi.quantity end
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    left join public.inventory_cost_allocations a
      on a.source_type = 'order' and a.source_item_id = oi.id
    where o.status = 'ready' and o.ready_at::date between p_from and p_to
  )
  select coalesce(sum(revenue), 0)::numeric(14, 2),
         coalesce(sum(cost), 0)::numeric(14, 2),
         coalesce(sum(unknown_quantity), 0)::integer
  into v_revenue, v_cost, v_unknown_items
  from transactions;

  select coalesce(sum(amount), 0)::numeric(14, 2)
  into v_expenses
  from public.operating_expenses
  where expense_date between p_from and p_to;

  with item_totals as (
    select si.product_id,
      sum((si.quantity - si.returned_quantity) * si.unit_price)::numeric(14, 2) as revenue,
      sum(case when a.cost_complete
        then a.cost_total * (si.quantity - si.returned_quantity) / nullif(si.quantity, 0)
        else 0 end)::numeric(14, 2) as cost,
      sum(case when a.cost_complete then 0 else si.quantity - si.returned_quantity end)::integer as unknown_quantity
    from public.sale_items si
    join public.sales s on s.id = si.sale_id
    left join public.inventory_cost_allocations a
      on a.source_type = 'sale' and a.source_item_id = si.id
    where s.created_at::date between p_from and p_to
    group by si.product_id
    union all
    select oi.product_id,
      sum(oi.quantity * oi.unit_price)::numeric(14, 2),
      sum(case when a.cost_complete then a.cost_total else 0 end)::numeric(14, 2),
      sum(case when a.cost_complete then 0 else oi.quantity end)::integer
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    left join public.inventory_cost_allocations a
      on a.source_type = 'order' and a.source_item_id = oi.id
    where o.status = 'ready' and o.ready_at::date between p_from and p_to
    group by oi.product_id
  ),
  product_transactions as (
    select product_id, sum(revenue)::numeric(14, 2) as revenue,
      sum(cost)::numeric(14, 2) as cost, sum(unknown_quantity)::integer as unknown_quantity
    from item_totals group by product_id
  ),
  product_stock_cost as (
    select b.product_id,
      coalesce(sum(b.quantity_remaining * b.unit_cost), 0)::numeric(14, 2) as cost_total,
      coalesce(sum(b.quantity_remaining), 0)::integer as quantity,
      count(*) filter (where b.quantity_remaining > 0 and b.unit_cost is null)::integer as unknown_batches
    from public.inventory_batches b
    where b.quantity_remaining > 0
    group by b.product_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id,
    'name', p.name,
    'stock', p.stock,
    'price', p.price,
    'margin_percent', p.margin_percent,
    'effective_margin_percent', coalesce(p.margin_percent, v_margin),
    'current_unit_cost', case
      when p.stock = 0 then null
      when coalesce(sc.quantity, 0) <> p.stock or coalesce(sc.unknown_batches, 0) > 0 then null
      else round(sc.cost_total / nullif(sc.quantity, 0), 2)
    end,
    'opening_cost_missing', p.stock > 0 and (
      coalesce(sc.quantity, 0) <> p.stock or coalesce(sc.unknown_batches, 0) > 0
    ),
    'revenue', coalesce(pt.revenue, 0),
    'cost', coalesce(pt.cost, 0),
    'gross_profit', coalesce(pt.revenue, 0) - coalesce(pt.cost, 0),
    'unknown_quantity', coalesce(pt.unknown_quantity, 0)
  ) order by p.name), '[]'::jsonb)
  into v_products
  from public.products p
  left join product_stock_cost sc on sc.product_id = p.id
  left join product_transactions pt on pt.product_id = p.id
  where p.active;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'category', category, 'description', description,
    'amount', amount, 'expense_date', expense_date, 'created_at', created_at
  ) order by expense_date desc, created_at desc), '[]'::jsonb)
  into v_expense_rows
  from (
    select id, category, description, amount, expense_date, created_at
    from public.operating_expenses
    where expense_date between p_from and p_to
    order by expense_date desc, created_at desc
    limit 500
  ) expenses;

  return jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'default_margin_percent', v_margin,
    'revenue', v_revenue,
    'cost_of_goods_sold', v_cost,
    'gross_profit', v_revenue - v_cost,
    'expenses', v_expenses,
    'net_profit', v_revenue - v_cost - v_expenses,
    'unknown_cost_quantity', v_unknown_items,
    'products', v_products,
    'expense_rows', v_expense_rows
  );
end;
$$;

revoke all on function public.consume_inventory_batches(uuid, integer) from public, anon, authenticated;
revoke all on function public.refresh_product_sale_price(uuid) from public, anon, authenticated;
revoke all on function public.capture_inventory_cost(text, uuid, uuid, integer) from public, anon, authenticated;
revoke all on function public.restock_product(uuid, integer, numeric) from public, anon, authenticated;
grant execute on function public.restock_product(uuid, integer, numeric) to authenticated;
revoke all on function public.set_default_profit_margin(numeric) from public, anon, authenticated;
grant execute on function public.set_default_profit_margin(numeric) to authenticated;
revoke all on function public.set_product_profit_margin(uuid, numeric) from public, anon, authenticated;
grant execute on function public.set_product_profit_margin(uuid, numeric) to authenticated;
revoke all on function public.set_opening_inventory_unit_cost(uuid, numeric) from public, anon, authenticated;
grant execute on function public.set_opening_inventory_unit_cost(uuid, numeric) to authenticated;
revoke all on function public.complete_order(uuid) from public, anon;
grant execute on function public.complete_order(uuid) to authenticated;
revoke all on function public.record_daily_sales(jsonb) from public, anon;
grant execute on function public.record_daily_sales(jsonb) to authenticated;
revoke all on function public.return_sale_item(uuid, integer, text) from public, anon;
grant execute on function public.return_sale_item(uuid, integer, text) to authenticated;
revoke all on function public.edit_sale_items(uuid, jsonb, text) from public, anon;
grant execute on function public.edit_sale_items(uuid, jsonb, text) to authenticated;
revoke all on function public.accounting_report(date, date) from public, anon, authenticated;
grant execute on function public.accounting_report(date, date) to authenticated;

revoke select on public.order_items, public.sale_items from authenticated;
grant select (id, order_id, product_id, product_name, quantity, unit_price, created_at)
  on public.order_items to authenticated;
grant select (id, sale_id, product_id, product_name, quantity, returned_quantity, unit_price)
  on public.sale_items to authenticated;

notify pgrst, 'reload schema';
commit;
