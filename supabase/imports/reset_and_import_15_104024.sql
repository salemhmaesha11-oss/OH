-- DESTRUCTIVE: this transaction clears existing products, orders,
-- material requests/recommendations, sales, inventory movements and batches,
-- sale cost allocations, and operating expenses before importing the workbook.
-- It preserves employee profiles, Supabase Auth users, and accounting settings.
-- Back up the database before running. The transaction rolls back on any error.
--
-- The workbook contains no purchase costs or sale dates. Opening inventory
-- costs remain NULL. The sold quantities are one imported manual sale by seller
-- "oh1", dated yesterday (start of the previous database-local day).

begin;

create temporary table oh_inventory_import_source (
  name text primary key,
  input_quantity integer not null check (input_quantity >= 0),
  remaining_quantity integer not null check (remaining_quantity >= 0),
  sold_quantity integer not null check (sold_quantity >= 0),
  unit_price numeric(12, 2) not null check (unit_price >= 0),
  check (input_quantity = remaining_quantity + sold_quantity)
) on commit drop;

insert into oh_inventory_import_source
  (name, input_quantity, remaining_quantity, sold_quantity, unit_price)
values
    (U&'\0628\0648\062A\0642\0629 \0627\0644\0645\0646\064A\0648\0645', 25, 25, 0, 900),
    (U&'\062A\0648\0631\0634 \062F\0648\0646 \0642\0627\0639\062F\0629', 48, 41, 7, 250),
    (U&'\0633\0643\064A\0646 \062C\0628\0633', 20, 20, 0, 230),
    (U&'\0641\062A\064A\0644 \0642\0646\062F\064A\0644', 70, 56, 14, 20),
    (U&'\0642\0646\062F\064A\0644 \0645\0639\062F\0646', 49, 49, 0, 400),
    (U&'\0642\0648\0627\0639\062F \0635\0628 \062C\0628\0633', 135, 36, 99, 75),
    (U&'\0643\062C\0629', 120, 108, 12, 120),
    (U&'\0643\0645\0627\0645\0629 \0635\064A\0646\064A', 250, 250, 0, 10),
    (U&'\0645\0631\0628\0637 \0645\0639\062F\0646', 50, 50, 0, 350),
    (U&'\0645\0637\0628\0642 \0628\0644\0627\0633\062A\064A\0643 \0639\0627\062F\064A', 10, 10, 0, 1000),
    (U&'\0645\0637\0628\0642 \0645\0639\062F\0646\064A', 10, 10, 0, 1500),
    (U&'\0645\0641\0635\0644 \0628\0644\0644\0627\0633\062A\064A\0643 \0645\0639 \0628\0631\063A\064A', 75, 41, 34, 150),
    (U&'\0645\0644\0648\0642\0629 \0628\0644\0627\0633\062A\064A\0643', 120, 102, 18, 30),
    (U&'\0645\0644\0648\0642\0629 \0645\0639\062F\0646 Ameco', 20, 19, 1, 230),
    (U&'\0645\0646\062D\062A\0629 \0634\0645\0639 \0643\0628\064A\0631\0629 Ameco', 20, 20, 0, 170),
    (U&'\0645\0646\0634\0627\0631 / \064A\062F /', 100, 96, 4, 150),
    (U&'\0646\0635\0644\0629 \0645\0646\0634\0627\0631', 245, 203, 42, 50),
    (U&'\0645\0646\062D\062A\0629 \0634\0645\0639 \0635\063A\064A\0631\0629 Ameco', 20, 18, 2, 170),
    (U&'\0633\0643\064A\0646 \0634\0645\0639 \0643\0628\064A\0631\0629 Ameco', 75, 63, 12, 230),
    (U&'\0633\0643\064A\0646 \0634\0645\0639 \0635\063A\064A\0631\0629 Ameco', 55, 46, 9, 170),
    (U&'\0627\0633\0628\0627\062A\0648\0644 \0645\0639\062F\0646\064A', 100, 99, 1, 170),
    (U&'\0645\0637\0648\0627\0629 Ameco', 92, 87, 5, 750),
    (U&'\0645\0646\062D\062A\0629 \0646\0642\0637\064A\0629', 25, 18, 7, 170),
    (U&'\0645\0637\0627\0637 BMC  \0643\064A\0633', 51, 50, 1, 175),
    (U&'\0645\062C\0645\0648\0639\0629 \0645\0637\0627\0637 BMC \0639\0644\0628\0629', 2, 2, 0, 4750),
    (U&'\0627\0644\062C\064A\0646\0627\062A  \0643\064A\0633 BMC', 40, 40, 0, 140),
    (U&'\0627\0644\062C\064A\0646\0627\062A \0639\0644\0628\0629 BMC', 2, 2, 0, 700),
    (U&'\0627\0644\062C\064A\0646\0627\062A \0643\064A\0633 Hyedent', 411, 143, 268, 120),
    (U&'\0627\0644\062C\064A\0646\0627\062A  \0639\0644\0628\0629 Hyedent', 18, 2, 16, 550),
    (U&'\062C\0628\0633 \0623\0635\0641\0631', 373, 29, 344, 50),
    (U&'\062C\0628\0633 \0627\0628\064A\0636', 81, 64, 17, 50),
    (U&'\062C\0628\0633 \0632\0647\0631\064A', 103, 58, 45, 70),
    (U&'\0643\062D\0648\0644 \0623\0632\0631\0642', 96, 42, 54, 50),
    (U&'\0623\0648\062A\0627\062F \0645\0639\062F\0646\064A\0629', 245, 115, 130, 40),
    (U&'\0645\0634\0631\0637 \0642\0644\0645\064A \0641\0636\064A', 51, 44, 7, 200),
    (U&'\0627\0643\0631\064A\0644 \0628\0627\0631\062F', 165, 57, 108, 300),
    (U&'\0627\0643\0631\064A\0644 \062D\0627\0645\064A', 0, 0, 0, 300),
    (U&'\0639\0627\0632\0644 \0633\0644\0643\0627\062A BMS', 150, 91, 59, 150),
    (U&'\0632\064A\062A \0639\0627\0632\0644', 27, 21, 6, 50),
    (U&'\0634\0645\0639 \0623\062D\0645\0631 \0635\064A\0646\064A', 540, 440, 100, 50),
    (U&'\0634\0645\0639 \0623\062D\0645\0631 BMS', 140, 134, 6, 100),
    (U&'\0623\0633\0646\0627\0646 \062A\0646\0636\064A\062F', 90, 45, 45, 300),
    (U&'\0623\0645\062B\0644\0629 \062C\0628\0633 \0641\0631\0627\0632\0627\0643\0648 OH', 87, 87, 0, 50),
    (U&'\0623\0645\062B\0644\0629 \062C\0628\0633 \062F\0631\062F OH', 180, 109, 71, 50),
    (U&'\0643\0641\0648\0641', 450, 450, 0, 20),
    (U&'\0642\0637\0627\0639\0629', 6, 3, 3, 350),
    (U&'\0634\0627\0646\0627\062A \0635\064A\0646\064A\0629', 1390, 1175, 215, 10),
    (U&'\0634\0627\0646\0627\062A \062A\0631\0643\064A elmax', 700, 400, 300, 10),
    (U&'\0639\0644\0628\0629 \0628\0644\0627\0633\062A\064A\0643 \0635\063A\064A\0631\0629 \0634\0641\0627\0641', 1, 1, 0, 150),
    (U&'\0639\0644\0628\0629 \0628\0644\0627\0633\062A\064A\0643 \0648\0633\0637 \0634\0641\0627\0641', 1, 1, 0, 200),
    (U&'\0639\0644\0628\0629 \0628\0644\0627\0633\062A\064A\0643 \0643\0628\064A\0631\0629 \0634\0641\0627\0641', 1, 0, 1, 250),
    (U&'\0637\0648\0627\0628\0639 \0628\0644\0627\0633\062A\064A\0643 \0648\0637\0646\064A \0632\0648\062C', 400, 367, 33, 40),
    (U&'\0631\064A\0634\0629 \0645\062C\0645\0648\0639\0629 Mont mart', 6, 6, 0, 750),
    (U&'\0631\064A\0634\0629 Mont mart 14', 6, 6, 0, 250),
    (U&'\0631\064A\0634\0629 Mont mart 10', 108, 108, 0, 200),
    (U&'\0631\064A\0634\0629 Mont mart 8', 180, 59, 121, 180),
    (U&'\0631\064A\0634\0629  Mont mart 6', 53, 52, 1, 170),
    (U&'\062D\0642\064A\0628\0629 \0644\0627\0628\062A\0648\0628 \0644\0648\0646 \0632\064A\062A\064A', 2, 2, 0, 1250),
    (U&'\062D\0642\064A\0628\0629 \0628\0646\0627\062A\064A 487 S', 1, 1, 0, 1500),
    (U&'\062D\0642\064A\0628\0629 \0628\0646\0627\062A\064Aw 201', 1, 1, 0, 1500),
    (U&'\062F\0641\062A\0631 \0627\062E\062A\0635\0627\0635', 5, 5, 0, 350),
    (U&'\0643\0648\0628 \0627\062E\062A\0635\0627\0635', 7, 7, 0, 250),
    (U&'\0627\0644\062A\0643\0648 \0635\0627\0631\0648\062E', 180, 143, 37, 30),
    (U&'\0633\0644\0643 \0633\062A\0627\0646\0644\0633\0633\062A\064A\0644', 1540, 1540, 0, 50),
    (U&'\0645\0634\0631\0637 \0642\0644\0645\064A \0623\0635\0641\0631', 7, 5, 2, 250),
    (U&'\0635\0627\0628\0648\0646 \0632\0647\0631 \0632\064A\062A\0648\0646', 1, 1, 0, 50),
    (U&'\0631\064A\0634\0629 Mont mart 4', 60, 57, 3, 150),
    (U&'\0642\0644\0645 \062A\0633\0648\064A\062F', 120, 120, 0, 50),
    (U&'\0642\0646\062F\064A\0644 \0632\062C\0627\062C\064A \0635\063A\064A\0631', 89, 82, 7, 350),
    (U&'\0642\0646\062F\064A\0644 \0632\062C\0627\062C\064A \0643\0628\064A\0631', 99, 99, 0, 450),
    (U&'\0645\0631\064A\0648\0644 \0623\0628\064A\0636 \0645\0643\0644\0641 \0632\0647\0631\064A', 3, 3, 0, 1650),
    (U&'\0645\0631\064A\0648\0644 \0623\0628\064A\0636 \0634\063A\0641', 18, 17, 1, 1500),
    (U&'\0645\0631\064A\0648\0644 \0623\0628\064A\0636 \0625\064A\0644\064A\063A\0627\0646\062A', 10, 10, 0, 1250),
    (U&'\062C\0627\0643\064A\062A \0623\0633\0646\0627\0646', 5, 5, 0, 2000),
    (U&'\063A\0637\0627\0621 \0631\0623\0633 \0647\0648\0633\0628\064A\0643\0631 \0645\0644\0648\0646', 18, 18, 0, 220),
    (U&'\063A\0637\0627\0621 \0631\0623\0633 \0627\0628\064A\0636', 20, 11, 9, 150),
    (U&'\0628\0637\0627\0642\0629 \0627\0633\0645\064A\0629 \0632\064A\0631\0648', 19, 10, 9, 50),
    (U&'\0628\0637\0627\0642\0629 \0627\0633\0645\064A\0629', 84, 65, 19, 40),
    (U&'\0634\0645\0639 Adl', 24, 13, 11, 200),
    (U&'\0627\0628\0631\0634\0627\0626\0643\0629', 210, 160, 50, 50),
    (U&'\0648\0631\0642 \0645\0644\0645', 101, 7, 94, 10),
    (U&'\0645\0633\0637\0631\0629 20\0633\0645', 20, 15, 5, 30),
    (U&'\0643\0631\062A\0648\0646\0629 \0628\0637\0627\0642\0629', 355, 72, 283, 20),
    (U&'\062D\0642\064A\0628\0629 \0644\0648\0646 \0623\0628\064A\0636 \0645\0639 \0642\0641\0644', 3, 3, 0, 1500),
    (U&'\0645\0642\0635', 3, 3, 0, 100),
    (U&'\0644\0648\062D \0632\062C\0627\062C\064A', 100, 72, 28, 100),
    (U&'\0642\0644\0645 \0623\0632\0631\0642 \0632\064A\0631\0648', 50, 50, 0, 40),
    (U&'\0642\0644\0645 xo', 100, 100, 0, 40),
    (U&'\0642\0644\0645 \0643\0644\0627\0631\0648', 50, 50, 0, 30),
    (U&'\0642\0644\0645 \0631\0635\0627\0635', 24, 24, 0, 40),
    (U&'\0645\062D\0627\064A\0629 +\0628\0631\0627\064A\0629', 50, 50, 0, 30),
    (U&'\062F\0641\062A\0631 \0635\0628\0627\063A \0648\0633\0637 70', 10, 10, 0, 100),
    (U&'\062F\0641\062A\0631 \0635\0628\0627\063A \0643\0628\064A\063170', 10, 10, 0, 120),
    (U&'\0642\0644\0645 \0644\0648\062D', 36, 36, 0, 30),
    (U&'\062E\0632\0641 \062F\064A\0646\062A\064A\0646 \0643\064A\0633 2 \063A\0631\0627\0645', 103, 63, 40, 200),
    (U&'\0645\0641\0635\0644 \0628\0644\0644\0627\0633\062A\064A\0643 \0628\062F\0648\0646 \0628\0631\063A\064A', 20, 20, 0, 100),
    (U&'\0643\0627\0633\0627\062A \0623\0643\0631\064A\0644', 72, 68, 4, 100),
    (U&'\0627\0633\0641\0646\062C \062E\0632\0641', 6, 6, 0, 250),
    (U&'\0634\0645\0639 Adl \062B\0644\0627\062B \0623\0644\0648\0627\0646', 1, 1, 0, 550),
    (U&'\0645\062D\0627\0631\0645 \0645\0639\0637\0631\0629', 7, 7, 0, 100),
    (U&'\062D\0642\064A\0628\0629 \0631\062C\0627\0644\064A SS', 2, 2, 0, 1500);

create temporary table oh_inventory_import_context (
  seller_id uuid
) on commit drop;

do $preflight$
declare
  v_seller_id uuid;
  v_source_count integer;
  v_input_total bigint;
  v_stock_total bigint;
  v_sold_total bigint;
  v_sales_total numeric;
  v_required_tables text[] := array[
    'public.profiles', 'public.products', 'public.orders', 'public.order_items',
    'public.material_requests', 'public.sales', 'public.sale_items',
    'public.sale_adjustments', 'public.inventory_movements',
    'public.inventory_batches', 'public.inventory_cost_allocations',
    'public.operating_expenses', 'public.accounting_settings'
  ];
  v_table text;
begin
  foreach v_table in array v_required_tables loop
    if to_regclass(v_table) is null then
      raise exception 'Required table % is missing; apply the project Supabase migrations first', v_table;
    end if;
  end loop;

  select id into v_seller_id
  from public.profiles
  where lower(btrim(username)) = 'oh1' and role = 2;
  if v_seller_id is null then
    raise exception 'Seller account "oh1" (role 2) was not found; no data was deleted';
  end if;

  select count(*), coalesce(sum(input_quantity), 0),
         coalesce(sum(remaining_quantity), 0), coalesce(sum(sold_quantity), 0),
         coalesce(sum(sold_quantity * unit_price), 0)
  into v_source_count, v_input_total, v_stock_total, v_sold_total, v_sales_total
  from oh_inventory_import_source;

  if v_source_count <> 101 or v_input_total <> 11534 or v_stock_total <> 8714
    or v_sold_total <> 2820 or v_sales_total <> 225980 then
    raise exception 'Workbook validation failed (rows %, input %, remaining %, sold %, sales %); no data was deleted',
      v_source_count, v_input_total, v_stock_total, v_sold_total, v_sales_total;
  end if;

  insert into oh_inventory_import_context values (v_seller_id);
end
$preflight$;

-- Clear operating data only. Profiles/Auth users and accounting settings remain.
delete from public.material_requests;
delete from public.order_items;
delete from public.orders;
delete from public.sale_adjustments;
delete from public.sale_items;
delete from public.sales;
delete from public.inventory_movements;
delete from public.inventory_cost_allocations;
delete from public.inventory_batches;
delete from public.operating_expenses;
delete from public.products;

insert into public.products (name, category, price, stock, total_sold, active)
select name, U&'\0645\0648\0627\062F \0627\0633\062A\0647\0644\0627\0643\064A\0629',
       unit_price, remaining_quantity, sold_quantity, true
from oh_inventory_import_source
order by name;

insert into public.inventory_batches
  (product_id, quantity_received, quantity_remaining, unit_cost)
select p.id, s.input_quantity, s.remaining_quantity, null
from oh_inventory_import_source s
join public.products p on p.name = s.name
where s.input_quantity > 0;

insert into public.inventory_movements
  (product_id, product_name, actor_id, movement_type, quantity_delta, note)
select p.id, p.name, c.seller_id, 'restock', s.input_quantity,
       U&'\0627\0633\062A\064A\0631\0627\062F \0627\0641\062A\062A\0627\062D\064A \0645\0646 \0645\0644\0641 15_104024.xlsx'
from oh_inventory_import_source s
join public.products p on p.name = s.name
cross join oh_inventory_import_context c
where s.input_quantity > 0;

insert into public.inventory_movements
  (product_id, product_name, actor_id, movement_type, quantity_delta, note)
select p.id, p.name, c.seller_id, 'sale', -s.sold_quantity,
       U&'\0645\0628\064A\0639\0627\062A \062A\0627\0631\064A\062E\064A\0629 \0645\0633\062A\0648\0631\062F\0629 \0645\0646 \0645\0644\0641 15_104024.xlsx'
from oh_inventory_import_source s
join public.products p on p.name = s.name
cross join oh_inventory_import_context c
where s.sold_quantity > 0;

do $import_sales$
declare
  v_seller_id uuid;
  v_sale_id uuid;
begin
  select seller_id into v_seller_id from oh_inventory_import_context;

  insert into public.sales (seller_id, created_at)
  values (v_seller_id, date_trunc('day', now()) - interval '1 day')
  returning id into v_sale_id;

  insert into public.sale_items
    (sale_id, product_id, product_name, quantity, unit_price)
  select v_sale_id, p.id, p.name, s.sold_quantity, s.unit_price
  from oh_inventory_import_source s
  join public.products p on p.name = s.name
  where s.sold_quantity > 0
  order by s.name;

  -- The workbook has no purchase-cost data; preserve unknown cost as NULL.
  insert into public.inventory_cost_allocations
    (source_type, source_item_id, cost_total, cost_complete)
  select 'sale', si.id, null, false
  from public.sale_items si
  where si.sale_id = v_sale_id;
end
$import_sales$;

commit;

select count(*) as imported_products,
       sum(stock) as remaining_units,
       sum(total_sold) as imported_sold_units
from public.products;

select count(distinct s.id) as imported_sales,
       count(si.id) as imported_sale_lines,
       coalesce(sum(si.quantity), 0) as sold_units,
       coalesce(sum(si.quantity * si.unit_price), 0) as sales_total
from public.sales s
left join public.sale_items si on si.sale_id = s.id
join public.profiles p on p.id = s.seller_id
where lower(btrim(p.username)) = 'oh1'
  and s.created_at >= date_trunc('day', now()) - interval '1 day'
  and s.created_at < date_trunc('day', now());
