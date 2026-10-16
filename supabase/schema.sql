-- Run in the Supabase SQL Editor for a new project.
-- Create the first owner in Supabase Auth with an email such as
-- ownername@users.sinna.invalid, then assign that Auth user's profile:
-- update public.profiles
-- set username = 'ownername', full_name = 'Owner Name', role = 1
-- where id = '<auth-user-uuid>';

create extension if not exists pgcrypto;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text,
  full_name text not null default '',
  role smallint not null default 0 check (role in (0, 1, 2)),
  created_at timestamptz not null default now()
);

create unique index profiles_username_lower_idx
  on public.profiles (lower(username))
  where username is not null;

-- Employee identity is linked to Supabase Auth by UUID.
-- Passwords are managed and securely hashed by Supabase Auth; never duplicate
-- password or password-hash values in the application profile tables.
create or replace view public.employees
with (security_invoker = true)
as
select id, username, full_name, role, created_at
from public.profiles
where role in (1, 2);

grant select on public.employees to authenticated, service_role;

create table public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null,
  icon text not null default '📦',
  image_url text,
  price numeric(12, 2) not null check (price >= 0),
  stock integer not null default 0 check (stock >= 0),
  total_sold integer not null default 0 check (total_sold >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number bigint generated always as identity unique,
  student_id uuid references public.profiles(id) on delete set null,
  student_name text not null,
  student_phone text,
  status text not null default 'pending'
    check (status in ('pending', 'preparing', 'ready', 'cancelled')),
  created_at timestamptz not null default now(),
  ready_at timestamptz
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  quantity integer not null check (quantity > 0),
  unit_price numeric(12, 2) not null check (unit_price >= 0),
  created_at timestamptz not null default now()
);

create table public.sales (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  quantity integer not null check (quantity > 0),
  unit_price numeric(12, 2) not null check (unit_price >= 0)
);

create table public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  actor_id uuid references public.profiles(id) on delete set null,
  movement_type text not null
    check (movement_type in ('restock', 'order_fulfillment', 'sale', 'adjustment')),
  quantity_delta integer not null check (quantity_delta <> 0),
  note text not null default '',
  created_at timestamptz not null default now()
);

create index orders_student_created_idx on public.orders(student_id, created_at desc);
create index orders_status_created_idx on public.orders(status, created_at);
create index order_items_order_idx on public.order_items(order_id);
create index sales_created_idx on public.sales(created_at desc);
create index inventory_movements_product_created_idx
  on public.inventory_movements(product_id, created_at desc);

create or replace function public.current_profile_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case role
    when 1 then 'owner'
    when 2 then 'seller'
    when 0 then 'student'
  end
  from public.profiles
  where id = (select auth.uid())
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger products_set_updated_at
before update on public.products
for each row execute function public.set_updated_at();

create or replace function public.create_profile_for_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, username, full_name)
  values (
    new.id,
    lower(nullif(new.raw_user_meta_data ->> 'username', '')),
    coalesce(new.raw_user_meta_data ->> 'full_name', '')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.create_profile_for_auth_user();

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.inventory_movements enable row level security;

grant usage on schema public to anon, authenticated, service_role;
grant select on public.products to anon, authenticated;
grant select, insert, update, delete on public.products to authenticated;
grant select, update on public.profiles to authenticated;
grant select on public.orders, public.order_items, public.sales, public.sale_items,
  public.inventory_movements to authenticated;

create policy "Users read their own profile; owners read all"
on public.profiles for select to authenticated
using (id = (select auth.uid()) or public.current_profile_role() = 'owner');

create policy "Owners update profiles"
on public.profiles for update to authenticated
using (public.current_profile_role() = 'owner')
with check (public.current_profile_role() = 'owner');

create policy "Anyone can read active products"
on public.products for select
using (active or public.current_profile_role() in ('seller', 'owner'));

create policy "Owners manage products"
on public.products for all to authenticated
using (public.current_profile_role() = 'owner')
with check (public.current_profile_role() = 'owner');

create policy "Students read own orders; staff read all"
on public.orders for select to authenticated
using (
  student_id = (select auth.uid())
  or public.current_profile_role() in ('seller', 'owner')
);

create policy "Users read visible order items"
on public.order_items for select to authenticated
using (
  exists (
    select 1 from public.orders o
    where o.id = order_id
      and (
        o.student_id = (select auth.uid())
        or public.current_profile_role() in ('seller', 'owner')
      )
  )
);

create policy "Staff read sales"
on public.sales for select to authenticated
using (public.current_profile_role() in ('seller', 'owner'));

create policy "Staff record sales as themselves"
on public.sales for insert to authenticated
with check (
  seller_id = (select auth.uid())
  and public.current_profile_role() in ('seller', 'owner')
);

create policy "Staff read sale items"
on public.sale_items for select to authenticated
using (
  exists (
    select 1 from public.sales s
    where s.id = sale_id
      and public.current_profile_role() in ('seller', 'owner')
  )
);

create policy "Staff add sale items"
on public.sale_items for insert to authenticated
with check (
  exists (
    select 1 from public.sales s
    where s.id = sale_id and s.seller_id = (select auth.uid())
  )
);

create policy "Owners read inventory history"
on public.inventory_movements for select to authenticated
using (public.current_profile_role() = 'owner');

create or replace function public.place_guest_order(p_student_name text, p_student_phone text, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_entry jsonb;
  v_product public.products%rowtype;
  v_quantity integer;
  v_items jsonb := '[]'::jsonb;
begin
  if nullif(trim(p_student_name), '') is null or length(trim(p_student_name)) > 80 then
    raise exception 'Enter a student name up to 80 characters';
  end if;
  if nullif(trim(p_student_phone), '') is null
    or length(trim(p_student_phone)) > 25
    or trim(p_student_phone) !~ '^\+?[0-9 ()-]+$'
    or length(regexp_replace(trim(p_student_phone), '[^0-9]', '', 'g')) not between 7 and 15 then
    raise exception 'Enter a valid student phone number';
  end if;
  if p_items is null or jsonb_typeof(p_items) is distinct from 'array'
    or jsonb_array_length(p_items) = 0 then
    raise exception 'At least one order item is required';
  end if;

  insert into public.orders (student_id, student_name, student_phone)
  values (null, trim(p_student_name), trim(p_student_phone))
  returning * into v_order;

  for v_entry in select value from jsonb_array_elements(p_items)
  loop
    if (v_entry ->> 'product_id') is null
      or (v_entry ->> 'quantity') !~ '^[1-9][0-9]*$' then
      raise exception 'Each order item requires a product and positive integer quantity';
    end if;

    v_quantity := (v_entry ->> 'quantity')::integer;
    select * into v_product
    from public.products
    where id = (v_entry ->> 'product_id')::uuid and active
    for update;

    if not found or v_product.stock < v_quantity then
      raise exception 'Product not found or insufficient stock';
    end if;

    insert into public.order_items
      (order_id, product_id, product_name, quantity, unit_price)
    values
      (v_order.id, v_product.id, v_product.name, v_quantity, v_product.price);

    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'product_id', v_product.id,
      'product_name', v_product.name,
      'quantity', v_quantity,
      'unit_price', v_product.price
    ));
  end loop;

  return jsonb_build_object(
    'id', v_order.id,
    'order_number', v_order.order_number,
    'created_at', v_order.created_at,
    'items', v_items
  );
end;
$$;

create or replace function public.place_order(p_items jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id uuid;
  v_student_name text;
  v_entry jsonb;
  v_product public.products%rowtype;
  v_quantity integer;
begin
  if public.current_profile_role() <> 'student' then
    raise exception 'Only students can place orders';
  end if;

  if p_items is null or jsonb_typeof(p_items) is distinct from 'array'
    or jsonb_array_length(p_items) = 0 then
    raise exception 'At least one order item is required';
  end if;

  select full_name into v_student_name
  from public.profiles where id = (select auth.uid());

  if nullif(trim(v_student_name), '') is null then
    raise exception 'A student name is required on the profile';
  end if;

  insert into public.orders (student_id, student_name)
  values ((select auth.uid()), trim(v_student_name))
  returning id into v_order_id;

  for v_entry in select value from jsonb_array_elements(p_items)
  loop
    if (v_entry ->> 'product_id') is null
      or (v_entry ->> 'quantity') !~ '^[1-9][0-9]*$' then
      raise exception 'Each order item requires a product and positive integer quantity';
    end if;

    v_quantity := (v_entry ->> 'quantity')::integer;

    select * into v_product
    from public.products
    where id = (v_entry ->> 'product_id')::uuid and active
    for update;

    if not found or v_product.stock < v_quantity then
      raise exception 'Product not found or insufficient stock';
    end if;

    insert into public.order_items
      (order_id, product_id, product_name, quantity, unit_price)
    values
      (v_order_id, v_product.id, v_product.name, v_quantity, v_product.price);
  end loop;

  return v_order_id;
end;
$$;

create or replace function public.start_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.current_profile_role() not in ('seller', 'owner') then
    raise exception 'Only staff can start preparing an order';
  end if;

  update public.orders
  set status = 'preparing'
  where id = p_order_id and status = 'pending';

  if not found then
    raise exception 'Order does not exist or is not pending';
  end if;
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
  if public.current_profile_role() not in ('seller', 'owner') then
    raise exception 'Only staff can complete an order';
  end if;

  select * into v_order
  from public.orders
  where id = p_order_id
  for update;

  if not found or v_order.status not in ('pending', 'preparing') then
    raise exception 'Order does not exist or is not awaiting fulfillment';
  end if;

  if not exists (select 1 from public.order_items where order_id = p_order_id) then
    raise exception 'An empty order cannot be completed';
  end if;

  for v_item in
    select * from public.order_items where order_id = p_order_id
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

    update public.products
    set stock = stock - v_item.quantity,
        total_sold = total_sold + v_item.quantity
    where id = v_item.product_id;

    insert into public.inventory_movements
      (product_id, product_name, actor_id, movement_type, quantity_delta, note)
    values
      (v_item.product_id, v_item.product_name, (select auth.uid()),
       'order_fulfillment', -v_item.quantity, 'Order ' || v_order.order_number);
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
begin
  if public.current_profile_role() not in ('seller', 'owner') then
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

    update public.products
    set stock = stock - v_quantity,
        total_sold = total_sold + v_quantity
    where id = v_product.id;

    insert into public.sale_items
      (sale_id, product_id, product_name, quantity, unit_price)
    values
      (v_sale_id, v_product.id, v_product.name, v_quantity, v_product.price);

    insert into public.inventory_movements
      (product_id, product_name, actor_id, movement_type, quantity_delta, note)
    values
      (v_product.id, v_product.name, (select auth.uid()),
       'sale', -v_quantity, 'Sale ' || v_sale_id::text);
  end loop;

  return v_sale_id;
end;
$$;

revoke all on function public.place_order(jsonb) from public, anon;
grant execute on function public.place_order(jsonb) to authenticated;
revoke all on function public.place_guest_order(text, text, jsonb) from public, authenticated;
grant execute on function public.place_guest_order(text, text, jsonb) to anon;
revoke all on function public.start_order(uuid) from public, anon;
grant execute on function public.start_order(uuid) to authenticated;
revoke all on function public.complete_order(uuid) from public, anon;
grant execute on function public.complete_order(uuid) to authenticated;
revoke all on function public.record_daily_sales(jsonb) from public, anon;
grant execute on function public.record_daily_sales(jsonb) to authenticated;

revoke all on function public.current_profile_role() from public, anon;
grant execute on function public.current_profile_role() to anon, authenticated;
