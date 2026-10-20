begin;

create table if not exists public.guest_order_request_keys (
  request_id uuid primary key,
  response jsonb not null,
  created_at timestamptz not null default now()
);

alter table public.guest_order_request_keys enable row level security;
revoke all on table public.guest_order_request_keys from public, anon, authenticated;

create or replace function public.place_guest_order(
  p_student_name text,
  p_student_phone text,
  p_items jsonb,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_response jsonb;
begin
  if p_request_id is null then
    raise exception 'A request identifier is required';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_request_id::text, 0)
  );

  select request.response into v_response
  from public.guest_order_request_keys as request
  where request.request_id = p_request_id;

  if found then
    return v_response;
  end if;

  v_response := public.place_guest_order(p_student_name, p_student_phone, p_items);

  insert into public.guest_order_request_keys (request_id, response)
  values (p_request_id, v_response);

  return v_response;
end;
$$;

revoke all on function public.place_guest_order(text, text, jsonb, uuid) from public, anon, authenticated;
grant execute on function public.place_guest_order(text, text, jsonb, uuid) to anon;

commit;
