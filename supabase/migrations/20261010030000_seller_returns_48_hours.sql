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

revoke all on function public.return_sale_item(uuid, integer, text) from public, anon;
grant execute on function public.return_sale_item(uuid, integer, text) to authenticated;

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
  if public.current_profile_role() = 'seller' and v_sale.created_at < now() - interval '48 hours' then
    raise exception 'Sellers can only edit sales within 48 hours';
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

revoke all on function public.edit_sale_items(uuid, jsonb, text) from public, anon;
grant execute on function public.edit_sale_items(uuid, jsonb, text) to authenticated;
