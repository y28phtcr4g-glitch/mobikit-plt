-- Run in a disposable Supabase project after all migrations. Always rolls back.
begin;
-- Simulate an unsafe legacy policy. Restrictive guards must still deny access.
-- Both this policy and all fixtures disappear on rollback.
create policy qa_legacy_storage_allow_all on storage.objects for all to public
using (true) with check (true);
insert into storage.buckets(id,name) values('qa-other','qa-other');
insert into storage.objects(bucket_id,name) values('qa-other','keep.webp');
insert into storage.objects(bucket_id,name)
values('mk-banners','weekly/00000000-0000-4000-8000-000000000081/a0.webp');
insert into auth.users(id,aud,role,email) values
 ('00000000-0000-4000-8000-000000000081','authenticated','authenticated','owner@example.invalid'),
 ('00000000-0000-4000-8000-000000000082','authenticated','authenticated','admin@example.invalid'),
 ('00000000-0000-4000-8000-000000000083','authenticated','authenticated','seller@example.invalid'),
 ('00000000-0000-4000-8000-000000000084','authenticated','authenticated','customer@example.invalid');
insert into public.mk_admin_members(user_id,role) values
 ('00000000-0000-4000-8000-000000000081','owner'),
 ('00000000-0000-4000-8000-000000000082','administrator'),
 ('00000000-0000-4000-8000-000000000083','seller');
set local role authenticated;
do $$
declare uid text; r bigint; denied boolean;
begin
 foreach uid in array array['00000000-0000-4000-8000-000000000083','00000000-0000-4000-8000-000000000084'] loop
  perform set_config('request.jwt.claim.sub',uid,true);
  denied=false;
  begin perform public.mk_admin_banner_get(); exception when insufficient_privilege then denied=true; end;
  if not denied then raise exception 'Draft leaked'; end if;
  denied=false;
  begin perform public.mk_admin_banner_save('https://example.com/a.jpg','A','',true,0); exception when insufficient_privilege then denied=true; end;
  if not denied then raise exception 'Unauthorized write'; end if;
 end loop;
 foreach uid in array array['00000000-0000-4000-8000-000000000081','00000000-0000-4000-8000-000000000082'] loop
  perform set_config('request.jwt.claim.sub',uid,true);
  select revision into r from public.mk_admin_banner_get();
  perform public.mk_admin_banner_save('https://example.com/a.jpg','A','',true,r);
  if not exists(select 1 from public.mk_weekly_banner() where image_url='https://example.com/a.jpg') then
   raise exception 'Published banner missing'; end if;
  denied=false;
  begin perform public.mk_admin_banner_save('https://example.com/a.jpg','Lost update','',true,r); exception when serialization_failure then denied=true; end;
  if not denied then raise exception 'Lost update accepted'; end if;
  select revision into r from public.mk_admin_banner_get();
  denied=false;
  begin perform public.mk_admin_banner_save('','A','',true,r); exception when invalid_parameter_value then denied=true; end;
  if not denied then raise exception 'Empty published image accepted'; end if;
  perform public.mk_admin_banner_save('https://example.com/a.jpg','A','',false,r);
  if exists(select 1 from public.mk_weekly_banner()) then raise exception 'Hidden banner leaked'; end if;
 end loop;
 -- Table API must remain closed even for an administrator. RPCs are the boundary.
 if has_table_privilege(current_user,'public.mk_admin_members','SELECT')
 or has_table_privilege(current_user,'public.mk_admin_members','INSERT')
 or has_table_privilege(current_user,'public.mk_admin_members','UPDATE')
 or has_table_privilege(current_user,'public.mk_site_banners','SELECT')
 or has_table_privilege(current_user,'public.mk_site_banners','UPDATE') then
  raise exception 'Direct table privileges exposed';
 end if;
 -- Metadata-level RLS checks; real Storage API size/MIME checks are separate.
 if not exists(select 1 from storage.objects where bucket_id='qa-other') then
  raise exception 'Guards affected another bucket'; end if;
 denied=false;
 begin update storage.objects set bucket_id='mk-banners',
  name='weekly/00000000-0000-4000-8000-000000000082/a8.webp' where bucket_id='qa-other';
 exception when insufficient_privilege then denied=true; end;
 if not denied then raise exception 'Cross-bucket move accepted'; end if;
 if exists(select 1 from storage.objects where bucket_id='mk-banners') then
  raise exception 'Object listing exposed'; end if;
 foreach uid in array array['00000000-0000-4000-8000-000000000081','00000000-0000-4000-8000-000000000082'] loop
  perform set_config('request.jwt.claim.sub',uid,true);
  insert into storage.objects(bucket_id,name) values('mk-banners','weekly/'||uid||'/a1.webp');
  denied=false;
  begin insert into storage.objects(bucket_id,name) values('mk-banners','weekly/not-my-uid/a1.webp');
  exception when insufficient_privilege then denied=true; end;
  if not denied then raise exception 'Foreign upload path accepted'; end if;
  denied=false;
  begin insert into storage.objects(bucket_id,name) values('mk-banners','weekly/'||uid||'/a1.svg');
  exception when insufficient_privilege then denied=true; end;
  if not denied then raise exception 'Unexpected extension accepted'; end if;
  begin
   update storage.objects set name='weekly/'||uid||'/a2.webp' where bucket_id='mk-banners';
   if found then raise exception 'Browser overwrite permitted'; end if;
  exception when insufficient_privilege then null; end;
  begin
   delete from storage.objects where bucket_id='mk-banners';
   if found then raise exception 'Browser delete permitted'; end if;
  exception when insufficient_privilege then null; end;
 end loop;
 foreach uid in array array['00000000-0000-4000-8000-000000000083','00000000-0000-4000-8000-000000000084'] loop
  perform set_config('request.jwt.claim.sub',uid,true);
  denied=false;
  begin insert into storage.objects(bucket_id,name) values('mk-banners','weekly/'||uid||'/a1.webp');
  exception when insufficient_privilege then denied=true; end;
  if not denied then raise exception 'Unauthorized Storage upload'; end if;
 end loop;
 denied=false;
 begin insert into public.mk_admin_members(user_id,role) values('00000000-0000-4000-8000-000000000084','owner'); exception when insufficient_privilege then denied=true; end;
 if not denied then raise exception 'Self promotion accepted'; end if;
end $$;
reset role;
-- Revocation must take effect without issuing a new JWT/session.
delete from public.mk_admin_members where user_id='00000000-0000-4000-8000-000000000082';
update auth.users set raw_user_meta_data='{"role":"owner","is_admin":true}'::jsonb
where id='00000000-0000-4000-8000-000000000082';
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000082',true);
set local role authenticated;
do $$ declare denied boolean=false; begin
 if public.mk_admin_role() is not null then raise exception 'Metadata granted a role'; end if;
 begin perform public.mk_admin_banner_save('https://example.com/a.jpg','Revoked','',true,0);
 exception when insufficient_privilege then denied=true; end;
 if not denied then raise exception 'Revoked administrator saved'; end if;
 denied=false;
 begin insert into storage.objects(bucket_id,name)
 values('mk-banners','weekly/00000000-0000-4000-8000-000000000082/a9.webp');
 exception when insufficient_privilege then denied=true; end;
 if not denied then raise exception 'Revoked administrator uploaded'; end if;
end $$;
reset role;
set local role anon;
do $$ declare denied boolean; begin
 if exists(select 1 from storage.objects where bucket_id='mk-banners') then
  raise exception 'Anonymous object listing exposed'; end if;
 if exists(select 1 from public.mk_weekly_banner()) then raise exception 'Anonymous draft leak'; end if;
 if has_function_privilege('anon','public.mk_admin_role()','execute') then raise exception 'Anonymous role RPC'; end if;
 if to_regprocedure('public.mk_admin_banner_save(text,text,text,boolean)') is not null then raise exception 'Old save exists'; end if;
 denied=false;
 begin perform public.mk_admin_banner_get(); exception when insufficient_privilege then denied=true; end;
 if not denied then raise exception 'Anonymous draft RPC accepted'; end if;
 denied=false;
 begin perform public.mk_admin_banner_save('https://example.com/a.jpg','A','',true,0);
 exception when insufficient_privilege then denied=true; end;
 if not denied then raise exception 'Anonymous save RPC accepted'; end if;
 denied=false;
 begin insert into storage.objects(bucket_id,name) values('mk-banners','weekly/00000000-0000-4000-8000-000000000081/a3.webp');
 exception when insufficient_privilege then denied=true; end;
 if not denied then raise exception 'Anonymous upload accepted'; end if;
end $$;
reset role;
rollback;
