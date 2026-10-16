begin;

create table public.material_requests (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  request_type text not null check (request_type in ('restock', 'forecast')),
  quantity integer not null check (quantity between 1 and 1000000),
  note text not null default '' check (length(note) <= 300),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  requester_name text not null,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected')),
  reviewed_by uuid references public.profiles(id) on delete set null,
  review_note text not null default '' check (length(review_note) <= 300),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  check (
    (status = 'pending' and reviewed_by is null and reviewed_at is null)
    or (status <> 'pending' and reviewed_by is not null and reviewed_at is not null)
  )
);

create index material_requests_created_idx
  on public.material_requests(created_at desc);
create index material_requests_requester_idx
  on public.material_requests(requester_id, created_at desc);
create index material_requests_pending_idx
  on public.material_requests(created_at desc)
  where status = 'pending';

alter table public.material_requests enable row level security;

create policy "Staff read own requests; owners read all"
on public.material_requests for select to authenticated
using (
  public.current_profile_role() = 'owner'
  or (
    public.current_profile_role() = 'seller'
    and requester_id = (select auth.uid())
  )
);

grant select on public.material_requests to authenticated;

create or replace function public.submit_material_request(
  p_product_id uuid,
  p_request_type text,
  p_quantity integer,
  p_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_product_name text;
  v_requester_name text;
  v_request_id uuid;
begin
  if public.current_profile_role() is distinct from 'seller' then
    raise exception 'Only sellers can submit material requests';
  end if;
  if p_request_type is null or p_request_type not in ('restock', 'forecast') then
    raise exception 'Choose a valid material request type';
  end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 1000000 then
    raise exception 'Enter a valid positive quantity';
  end if;
  if length(coalesce(p_note, '')) > 300 then
    raise exception 'The request note must be no longer than 300 characters';
  end if;

  select name into v_product_name
  from public.products
  where id = p_product_id and active
  for share;
  if not found then
    raise exception 'The selected product is unavailable';
  end if;

  select full_name into v_requester_name
  from public.profiles
  where id = (select auth.uid());
  if not found then
    raise exception 'Seller profile is unavailable';
  end if;

  insert into public.material_requests (
    product_id, product_name, request_type, quantity, note,
    requester_id, requester_name
  )
  values (
    p_product_id, v_product_name, p_request_type, p_quantity,
    trim(coalesce(p_note, '')), (select auth.uid()), v_requester_name
  )
  returning id into v_request_id;

  return v_request_id;
end;
$$;

create or replace function public.review_material_request(
  p_request_id uuid,
  p_status text,
  p_review_note text default ''
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.current_profile_role() is distinct from 'owner' then
    raise exception 'Only owners can review material requests';
  end if;
  if p_status is null or p_status not in ('approved', 'rejected') then
    raise exception 'Choose approval or rejection';
  end if;
  if length(coalesce(p_review_note, '')) > 300 then
    raise exception 'The review note must be no longer than 300 characters';
  end if;

  update public.material_requests
  set status = p_status,
      review_note = trim(coalesce(p_review_note, '')),
      reviewed_by = (select auth.uid()),
      reviewed_at = now()
  where id = p_request_id and status = 'pending';
  if not found then
    raise exception 'The request does not exist or has already been reviewed';
  end if;
end;
$$;

revoke all on function public.submit_material_request(uuid, text, integer, text)
  from public, anon, authenticated;
grant execute on function public.submit_material_request(uuid, text, integer, text)
  to authenticated;
revoke all on function public.review_material_request(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.review_material_request(uuid, text, text)
  to authenticated;

notify pgrst, 'reload schema';
commit;
