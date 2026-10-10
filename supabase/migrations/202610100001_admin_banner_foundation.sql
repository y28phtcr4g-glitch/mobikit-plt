-- MOBIKIT PLT: secure foundation for owner-managed weekly banner.
-- Apply manually in the Supabase SQL editor after reviewing the migration.
create table if not exists public.mk_admin_members (
 user_id uuid primary key references auth.users(id) on delete cascade,
 role text not null check (role in ('owner','administrator','seller')),
 created_at timestamptz not null default now()
);
alter table public.mk_admin_members enable row level security;
revoke all on public.mk_admin_members from anon, authenticated;
-- Do not expose membership changes to the browser.
create table if not exists public.mk_site_banners (
 slot text primary key check (slot = 'weekly'),
 image_url text not null default '',
 title text not null default 'Акції тижня 🔥',
 subtitle text not null default '',
 published boolean not null default false,
 updated_at timestamptz not null default now(),
 updated_by uuid references auth.users(id)
);
alter table public.mk_site_banners enable row level security;
revoke all on public.mk_site_banners from anon, authenticated;
insert into public.mk_site_banners(slot) values ('weekly') on conflict do nothing;

create or replace function public.mk_weekly_banner()
returns table(image_url text,title text,subtitle text,published boolean)
language sql stable security definer set search_path = ''
as $$
 select b.image_url,b.title,b.subtitle,b.published
 from public.mk_site_banners b where b.slot='weekly' and b.published
$$;
revoke all on function public.mk_weekly_banner() from public;
grant execute on function public.mk_weekly_banner() to anon, authenticated;

create or replace function public.mk_admin_banner_save(
 p_image_url text,p_title text,p_subtitle text,p_published boolean
) returns void language plpgsql security definer set search_path = ''
as $$
begin
 if auth.uid() is null or not exists(
  select 1 from public.mk_admin_members m
  where m.user_id=auth.uid() and m.role in ('owner','administrator')
 ) then raise exception 'Not authorized' using errcode='42501'; end if;
 if length(coalesce(p_title,'')) not between 1 and 120
    or length(coalesce(p_subtitle,''))>500
    or length(coalesce(p_image_url,''))>2000
    or (coalesce(p_image_url,'')<>'' and p_image_url !~ '^https://[^[:space:]]+$')
 then raise exception 'Invalid banner fields'; end if;
 insert into public.mk_site_banners(slot,image_url,title,subtitle,published,updated_by,updated_at)
 values('weekly',coalesce(p_image_url,''),p_title,coalesce(p_subtitle,''),coalesce(p_published,false),auth.uid(),now())
 on conflict(slot) do update set image_url=excluded.image_url,title=excluded.title,
 subtitle=excluded.subtitle,published=excluded.published,updated_by=excluded.updated_by,updated_at=now();
end $$;
revoke all on function public.mk_admin_banner_save(text,text,text,boolean) from public;
grant execute on function public.mk_admin_banner_save(text,text,text,boolean) to authenticated;

-- IMPORTANT: bootstrap first owner ONLY from SQL editor using a verified auth.users UUID:
-- insert into public.mk_admin_members(user_id,role) values ('REAL-USER-UUID','owner');
-- Never put service_role credentials or owner assignment in public client JS.
