-- Apply after 202610100001. No membership is created by this migration.
begin;
create or replace function public.mk_admin_role()
returns text language sql stable security definer set search_path = ''
as $$ select role from public.mk_admin_members where user_id = auth.uid() $$;
revoke all on function public.mk_admin_role() from public, anon;
grant execute on function public.mk_admin_role() to authenticated;

create or replace function public.mk_admin_banner_get()
returns setof public.mk_site_banners
language plpgsql stable security definer set search_path = '' as $$
begin
 if coalesce(public.mk_admin_role(),'') not in ('owner','administrator') then
  raise exception 'Not authorized' using errcode='42501';
 end if;
 return query select * from public.mk_site_banners where slot='weekly';
end $$;
revoke all on function public.mk_admin_banner_get() from public, anon;
grant execute on function public.mk_admin_banner_get() to authenticated;

-- A revision prevents one editor from silently overwriting another editor.
alter table public.mk_site_banners add column if not exists revision bigint not null default 0;
drop function public.mk_admin_banner_save(text,text,text,boolean);
create function public.mk_admin_banner_save(
 p_image_url text,p_title text,p_subtitle text,p_published boolean,p_revision bigint
) returns bigint language plpgsql security definer set search_path = '' as $$
declare next_revision bigint;
begin
 if coalesce(public.mk_admin_role(),'') not in ('owner','administrator') then
  raise exception 'Not authorized' using errcode='42501';
 end if;
 if p_title is null or length(btrim(p_title)) not between 1 and 120
 or length(coalesce(p_subtitle,''))>500 or length(coalesce(p_image_url,''))>2000
 or (coalesce(p_image_url,'')<>'' and p_image_url !~ '^https://[^[:space:]"<>]+$')
 or (coalesce(p_published,false) and coalesce(p_image_url,'')='') then
  raise exception 'Invalid banner fields' using errcode='22023';
 end if;
 update public.mk_site_banners set image_url=coalesce(p_image_url,''),title=btrim(p_title),
 subtitle=coalesce(p_subtitle,''),published=coalesce(p_published,false),
 updated_by=auth.uid(),updated_at=clock_timestamp(),revision=revision+1
 where slot='weekly' and revision=p_revision returning revision into next_revision;
 if not found then raise exception 'Banner changed; reload before saving' using errcode='40001'; end if;
 return next_revision;
end $$;
revoke all on function public.mk_admin_banner_save(text,text,text,boolean,bigint) from public, anon;
grant execute on function public.mk_admin_banner_save(text,text,text,boolean,bigint) to authenticated;

-- Public marketing images only. Draft images are also accessible by URL.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('mk-banners','mk-banners',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=true,file_size_limit=excluded.file_size_limit,
 allowed_mime_types=excluded.allowed_mime_types;
create policy mk_banner_upload on storage.objects for insert to authenticated
with check(bucket_id='mk-banners' and public.mk_admin_role() in ('owner','administrator')
 and name ~ ('^weekly/' || auth.uid()::text || '/[0-9a-f-]+\.(jpg|png|webp)$'));
-- No browser overwrite/delete: existing published images remain intact.
commit;
