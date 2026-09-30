begin;
alter table public.mk_profiles add constraint mk_profiles_birthday_not_future
 check (birthday is null or birthday <= (now() at time zone 'Europe/Kyiv')::date) not valid;
alter table public.mk_profiles validate constraint mk_profiles_birthday_not_future;
commit;
