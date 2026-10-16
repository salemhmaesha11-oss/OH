-- Apply this migration instead of re-running schema.sql when the original
-- prototype schema has already been installed in Supabase.

alter table public.profiles
  add column if not exists username text;

create unique index if not exists profiles_username_lower_idx
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
-- Cast supports projects whose role column is already numeric.
where role::text in ('owner', 'seller', '1', '2');

grant select on public.employees to authenticated, service_role;

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
