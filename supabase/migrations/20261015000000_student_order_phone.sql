alter table public.orders
  add column if not exists student_phone text;

drop function if exists public.place_guest_order(text, jsonb);

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

revoke all on function public.place_guest_order(text, text, jsonb) from public, authenticated;
grant execute on function public.place_guest_order(text, text, jsonb) to anon;

notify pgrst, 'reload schema';
