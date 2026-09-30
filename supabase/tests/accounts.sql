begin;
create temporary table qa_results(test text,result text);
insert into auth.users(id,aud,role,email) values
('00000000-0000-4000-8000-000000000001','authenticated','authenticated','qa-one@example.invalid'),
('00000000-0000-4000-8000-000000000002','authenticated','authenticated','qa-two@example.invalid');
insert into public.mk_profiles(user_id,name,phone) values
('00000000-0000-4000-8000-000000000001','Перший Тест','+380990000011'),
('00000000-0000-4000-8000-000000000002','Другий Тест','+380990000012');
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
set local role authenticated;
do $$
declare o jsonb; n integer; failed boolean=false;
begin
select count(*) into n from public.mk_profiles;
if n<>1 then raise exception 'QA: other profile visible';end if;
update public.mk_profiles set name='Зміна Чужого' where user_id='00000000-0000-4000-8000-000000000002';
get diagnostics n=row_count;
if n<>0 then raise exception 'QA: other profile update';end if;
o=public.mk_create_order('00000000-0000-4000-8000-000000000011','00000000-0000-4000-8000-000000000012','{"payment":"pickup","buyerName":"Чуже Ім’я","buyerPhone":"+380990000099","items":[{"id":"walker-wts67","qty":1}]}');
if o->>'buyerPhone'<>'+380990000011' or o->>'ownerKey'<>'00000000-0000-4000-8000-000000000001' then raise exception 'QA: spoofed owner';end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
set local role authenticated;
do $$
declare n integer; failed boolean=false; oid uuid;
begin
select count(id) into n from public.mk_orders;
if n<>0 or public.mk_list_orders()<>'[]'::jsonb then raise exception 'QA: foreign order visible';end if;
begin
perform public.mk_create_order('00000000-0000-4000-8000-000000000011','00000000-0000-4000-8000-000000000012','{"payment":"pickup","items":[{"id":"walker-wts67","qty":1}]}');
exception when others then failed=true;end;
if not failed then raise exception 'QA: cross-user retry accepted';end if;
end $$;
reset role;
insert into qa_results values('Real authenticated role: own profile only, foreign profile update blocked','PASS'),('Authenticated buyer uses profile identity, ignores supplied owner/contact','PASS'),('Second user cannot read first user order or replay its request','PASS');
select * from qa_results;
rollback;


