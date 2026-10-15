-- Permissive policies combine with OR. These guards also constrain legacy policies.
-- Other buckets retain their existing policies. Service-role maintenance bypasses RLS.
begin;
revoke all on public.mk_admin_members, public.mk_site_banners from public, anon, authenticated;
create policy mk_banner_insert_guard on storage.objects as restrictive
for insert to public with check (
 bucket_id <> 'mk-banners' or (
  public.mk_admin_role() in ('owner','administrator')
  and name ~ ('^weekly/' || auth.uid()::text || '/[0-9a-f-]+\.(jpg|png|webp)$')
 )
);
-- Public asset delivery uses the public Storage endpoint, not object-table SELECT.
create policy mk_banner_select_guard on storage.objects as restrictive
for select to public using (bucket_id <> 'mk-banners');
create policy mk_banner_update_guard on storage.objects as restrictive
for update to public using (bucket_id <> 'mk-banners')
with check (bucket_id <> 'mk-banners');
create policy mk_banner_delete_guard on storage.objects as restrictive
for delete to public using (bucket_id <> 'mk-banners');
commit;
