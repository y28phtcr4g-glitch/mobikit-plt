-- Run in a disposable Supabase project after all migrations. Always rolls back.
begin;
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
 denied=false;
 begin insert into public.mk_admin_members(user_id,role) values('00000000-0000-4000-8000-000000000084','owner'); exception when insufficient_privilege then denied=true; end;
 if not denied then raise exception 'Self promotion accepted'; end if;
end $$;
reset role;
set local role anon;
do $$ begin
 if exists(select 1 from public.mk_weekly_banner()) then raise exception 'Anonymous draft leak'; end if;
 if has_function_privilege('anon','public.mk_admin_role()','execute') then raise exception 'Anonymous role RPC'; end if;
 if to_regprocedure('public.mk_admin_banner_save(text,text,text,boolean)') is not null then raise exception 'Old save exists'; end if;
end $$;
reset role;
rollback;
