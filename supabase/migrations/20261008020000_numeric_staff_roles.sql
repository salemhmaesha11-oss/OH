-- Convert employee roles to stable numeric values:
-- owner = 1, seller = 2, student/other = 0.

drop view if exists public.employees;

alter table public.profiles
  drop constraint if exists profiles_role_check;

alter table public.profiles
  alter column role drop default;

alter table public.profiles
  alter column role type smallint
  using (
    case role::text
      when 'owner' then 1
      when '1' then 1
      when 'seller' then 2
      when '2' then 2
      else 0
    end
  );

alter table public.profiles
  alter column role set default 0,
  alter column role set not null,
  add constraint profiles_role_check check (role in (0, 1, 2));

create or replace view public.employees
with (security_invoker = true)
as
select id, username, full_name, role, created_at
from public.profiles
where role in (1, 2);

grant select on public.employees to authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;

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

notify pgrst, 'reload schema';
