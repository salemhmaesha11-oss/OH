begin;

alter table public.products
  add column if not exists details text not null default '';

alter table public.products
  drop constraint if exists products_details_length_check;
alter table public.products
  add constraint products_details_length_check check (length(details) <= 1000);

create or replace view public.customer_products
with (security_barrier = true)
as
select id, name, category, icon, price, (stock > 0) as in_stock, image_url, details
from public.products
where active;

create or replace view public.staff_products
with (security_barrier = true)
as
select id, name, category, icon, price, stock, total_sold, image_url, details
from public.products
where active and public.current_profile_role() in ('seller', 'owner');

grant select on public.customer_products to anon, authenticated;
grant select on public.staff_products to authenticated;

alter table public.material_requests
  drop constraint if exists material_requests_status_check;
alter table public.material_requests
  add constraint material_requests_status_check
  check (status in ('pending', 'approved', 'rejected', 'withdrawn'));

create or replace function public.withdraw_material_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.current_profile_role() is distinct from 'seller' then
    raise exception 'Only sellers can withdraw their own requests';
  end if;

  update public.material_requests
  set status = 'withdrawn',
      review_note = 'Withdrawn by requester',
      reviewed_by = (select auth.uid()),
      reviewed_at = now()
  where id = p_request_id
    and requester_id = (select auth.uid())
    and status = 'pending';

  if not found then
    raise exception 'The request does not exist, is not pending, or belongs to another seller';
  end if;
end;
$$;

revoke all on function public.withdraw_material_request(uuid) from public, anon, authenticated;
grant execute on function public.withdraw_material_request(uuid) to authenticated;

create or replace function public.place_guest_order(
  p_student_name text,
  p_student_phone text,
  p_items jsonb
)
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
  v_student_name text;
  v_items jsonb := '[]'::jsonb;
begin
  v_student_name := regexp_replace(trim(coalesce(p_student_name, '')), '\s+', ' ', 'g');
  if length(v_student_name) = 0 or length(v_student_name) > 80
    or array_length(string_to_array(v_student_name, ' '), 1) < 3 then
    raise exception 'Enter a student name containing at least three parts (up to 80 characters)';
  end if;
  if coalesce(p_student_phone, '') !~ '^09[0-9]{8}$' then
    raise exception 'Enter a 10-digit student phone number beginning with 09';
  end if;
  if p_items is null or jsonb_typeof(p_items) is distinct from 'array'
    or jsonb_array_length(p_items) = 0 then
    raise exception 'At least one order item is required';
  end if;

  insert into public.orders (student_id, student_name, student_phone)
  values (null, v_student_name, p_student_phone)
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

revoke all on function public.place_guest_order(text, text, jsonb) from public, authenticated;
grant execute on function public.place_guest_order(text, text, jsonb) to anon;

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
  v_note text;
begin
  if public.current_profile_role() is distinct from 'owner' then
    raise exception 'Only owners can restock products';
  end if;
  if p_quantity is null or p_quantity < 1 then
    raise exception 'Restock quantity must be positive';
  end if;
  if p_unit_cost is not null and (p_unit_cost < 0 or p_unit_cost > 9999999999.99) then
    raise exception 'Enter a valid non-negative unit purchase cost';
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

  v_note := 'Restock: ' || p_quantity::text || ' units';
  if p_unit_cost is null then
    v_note := v_note || ' with no recorded unit cost';
  else
    v_note := v_note || ' at unit cost ' || round(p_unit_cost, 2)::text;
  end if;
  insert into public.inventory_movements
    (product_id, product_name, actor_id, movement_type, quantity_delta, note)
  values
    (v_product.id, v_product.name, (select auth.uid()), 'restock', p_quantity, v_note);

  perform public.refresh_product_sale_price(v_product.id);
  return v_product.stock;
end;
$$;

revoke all on function public.restock_product(uuid, integer, numeric) from public, anon, authenticated;
grant execute on function public.restock_product(uuid, integer, numeric) to authenticated;

create or replace function public.cancel_ready_order_internal(
  p_order_id uuid,
  p_actor_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_item public.order_items%rowtype;
  v_cost_total numeric(14, 2);
  v_cost_complete boolean;
  v_cost_cents bigint;
  v_base_cents bigint;
  v_remainder integer;
begin
  select * into v_order
  from public.orders
  where id = p_order_id
  for update;
  if not found or v_order.status <> 'ready' then
    raise exception 'Order does not exist or is not ready for pickup';
  end if;

  for v_item in
    select * from public.order_items where order_id = p_order_id
  loop
    if v_item.product_id is null then
      continue;
    end if;

    perform 1 from public.products where id = v_item.product_id for update;
    if not found then
      continue;
    end if;

    select coalesce(a.cost_complete, false), a.cost_total
    into v_cost_complete, v_cost_total
    from public.inventory_cost_allocations a
    where a.source_type = 'order' and a.source_item_id = v_item.id;
    if not found then
      v_cost_complete := false;
      v_cost_total := null;
    end if;

    if v_cost_complete and v_cost_total is not null then
      v_cost_cents := round(v_cost_total * 100)::bigint;
      v_base_cents := v_cost_cents / v_item.quantity;
      v_remainder := (v_cost_cents % v_item.quantity)::integer;
      if v_remainder > 0 then
        insert into public.inventory_batches
          (product_id, quantity_received, quantity_remaining, unit_cost)
        values
          (v_item.product_id, v_remainder, v_remainder, (v_base_cents + 1)::numeric / 100);
      end if;
      if v_item.quantity > v_remainder then
        insert into public.inventory_batches
          (product_id, quantity_received, quantity_remaining, unit_cost)
        values
          (v_item.product_id, v_item.quantity - v_remainder, v_item.quantity - v_remainder,
           v_base_cents::numeric / 100);
      end if;
    else
      insert into public.inventory_batches
        (product_id, quantity_received, quantity_remaining, unit_cost)
      values (v_item.product_id, v_item.quantity, v_item.quantity, null);
    end if;

    update public.products
    set stock = stock + v_item.quantity,
        total_sold = greatest(total_sold - v_item.quantity, 0),
        updated_at = now()
    where id = v_item.product_id;

    insert into public.inventory_movements
      (product_id, product_name, actor_id, movement_type, quantity_delta, note)
    values
      (v_item.product_id, v_item.product_name, p_actor_id, 'adjustment',
       v_item.quantity, coalesce(p_reason, 'Ready order canceled'));

    perform public.refresh_product_sale_price(v_item.product_id);
  end loop;

  update public.orders
  set status = 'cancelled'
  where id = p_order_id and status = 'ready';
end;
$$;

create or replace function public.cancel_ready_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(public.current_profile_role(), '') not in ('seller', 'owner') then
    raise exception 'Only staff can cancel a ready order';
  end if;

  perform public.cancel_ready_order_internal(p_order_id, (select auth.uid()), 'Ready order canceled manually');
end;
$$;

create or replace function public.expire_ready_orders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id uuid;
  v_cancelled integer := 0;
begin
  for v_order_id in
    select id
    from public.orders
    where status = 'ready'
      and ready_at <= now() - interval '24 hours'
    order by ready_at, id
    for update skip locked
  loop
    perform public.cancel_ready_order_internal(v_order_id, null, 'Automatically canceled after 24 hours without pickup');
    v_cancelled := v_cancelled + 1;
  end loop;

  return v_cancelled;
end;
$$;

revoke all on function public.cancel_ready_order_internal(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.cancel_ready_order(uuid) from public, anon;
grant execute on function public.cancel_ready_order(uuid) to authenticated;
revoke all on function public.expire_ready_orders() from public, anon, authenticated;

create or replace function public.inventory_valuation_report()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_known_value numeric(14, 2);
  v_unknown_quantity integer;
  v_inventory_quantity integer;
begin
  if public.current_profile_role() is distinct from 'owner' then
    raise exception 'Only owners can view inventory valuation';
  end if;

  with batch_totals as (
    select b.product_id,
      coalesce(sum(b.quantity_remaining), 0)::integer as quantity,
      coalesce(sum(b.quantity_remaining * b.unit_cost)
        filter (where b.unit_cost is not null), 0)::numeric(14, 2) as known_value,
      coalesce(sum(b.quantity_remaining)
        filter (where b.unit_cost is null), 0)::integer as unknown_quantity
    from public.inventory_batches b
    where b.quantity_remaining > 0
    group by b.product_id
  )
  select
    coalesce(sum(case when coalesce(bt.quantity, 0) <= p.stock
      then coalesce(bt.known_value, 0) else 0 end), 0)::numeric(14, 2),
    coalesce(sum(case when coalesce(bt.quantity, 0) > p.stock
      then p.stock
      else coalesce(bt.unknown_quantity, 0) + greatest(p.stock - coalesce(bt.quantity, 0), 0)
    end), 0)::integer,
    coalesce(sum(p.stock), 0)::integer
  into v_known_value, v_unknown_quantity, v_inventory_quantity
  from public.products p
  left join batch_totals bt on bt.product_id = p.id
  where p.active;

  return jsonb_build_object(
    'known_value', v_known_value,
    'unknown_quantity', v_unknown_quantity,
    'inventory_quantity', v_inventory_quantity
  );
end;
$$;

revoke all on function public.inventory_valuation_report() from public, anon, authenticated;
grant execute on function public.inventory_valuation_report() to authenticated;

create extension if not exists pg_cron;

do $$
declare
  v_job_id bigint;
begin
  select jobid into v_job_id
  from cron.job
  where jobname = 'oh-cancel-expired-ready-orders';
  if v_job_id is not null then
    perform cron.unschedule(v_job_id);
  end if;

  perform cron.schedule(
    'oh-cancel-expired-ready-orders',
    '*/5 * * * *',
    'select public.expire_ready_orders();'
  );
end;
$$;

notify pgrst, 'reload schema';
commit;
