begin;
do $$
declare uid uuid=gen_random_uuid(); rejected boolean=false;
begin
 insert into auth.users(id,aud,role,email) values(uid,'authenticated','authenticated','qa-birthday-'||uid::text||'@example.invalid');
 insert into public.mk_profiles(user_id,name,phone,birthday) values(uid,'Тест Дати','+380990000092','2000-02-29');
 begin update public.mk_profiles set birthday=(now() at time zone 'Europe/Kyiv')::date+1 where user_id=uid;exception when check_violation then rejected=true;end;
 if not rejected then raise exception 'QA: future birthday accepted';end if;
 update public.mk_profiles set birthday=(now() at time zone 'Europe/Kyiv')::date where user_id=uid;
 update public.mk_profiles set birthday=null where user_id=uid;
end $$;
select 'Future birth date rejected; leap day, today and empty date accepted' as test,'PASS' as result;
select convalidated as birthday_constraint_validated from pg_constraint where conrelid='public.mk_profiles'::regclass and conname='mk_profiles_birthday_not_future';
select count(*) as active_qa_fixture_orders from public.mk_orders where final_state is null and buyer_phone in ('+380990000001','+380990000011','+380990000096','+380990000097','+380990000098');
rollback;
