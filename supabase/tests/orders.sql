begin;
create temporary table qa_results(test text, result text);
create function pg_temp.reject_order(v jsonb) returns void language plpgsql as $$
begin
 begin
 perform public.mk_create_order(gen_random_uuid(),gen_random_uuid(),v);
 exception when others then return;
 end;
 raise exception 'QA: invalid order accepted: %',v;
end $$;
do $$
declare base jsonb='{"payment":"pickup","buyerName":"Тест Перевірка","buyerPhone":"+380990000001","items":[{"id":"walker-wts67","qty":1,"unitPrice":1}],"total":1}';
req uuid=gen_random_uuid(); tok uuid=gen_random_uuid(); first_order jsonb; repeated jsonb; oid uuid; failed boolean; v jsonb;
begin
first_order=public.mk_create_order(req,tok,base);
oid=(first_order->>'serverId')::uuid;
if (first_order->>'total')::numeric<>1399 or (first_order->'items'->0->>'unitPrice')::numeric<>1399 then raise exception 'QA: price tampering accepted';end if;
insert into qa_results values('Server price ignores submitted price/total','PASS');
repeated=public.mk_create_order(req,tok,base);
if repeated<>first_order or (select count(*) from public.mk_orders where request_id=req)<>1 then raise exception 'QA: duplicate request';end if;
insert into qa_results values('Repeated request produces one order','PASS');
failed=false;
begin perform public.mk_guest_order(req,gen_random_uuid());exception when others then failed=true;end;
if not failed then raise exception 'QA: wrong token read';end if;
failed=false;
begin perform public.mk_cancel_order(oid,null);exception when others then failed=true;end;
if not failed then raise exception 'QA: null token cancel';end if;
insert into qa_results values('Wrong guest token and NULL auth cannot read/cancel','PASS');
perform pg_temp.reject_order(base-'items');
perform pg_temp.reject_order(jsonb_set(base,'{items}','[]'));
perform pg_temp.reject_order(jsonb_set(base,'{items,0,qty}','-1'));
perform pg_temp.reject_order(jsonb_set(base,'{items,0,qty}','1.5'));
perform pg_temp.reject_order(jsonb_set(base,'{items}',base->'items'||base->'items'));
perform pg_temp.reject_order(jsonb_set(base,'{items}','[{"id":"cable-baseus-rapid-charge","variantKey":"2m-black","qty":1}]'));
perform pg_temp.reject_order(jsonb_set(base,'{items}','[{"id":"cable-walker-power-silicone-100w","variantKey":"2m-white","qty":1}]'));
perform pg_temp.reject_order(jsonb_set(base,'{items}','[{"id":"case-carbon","qty":1}]'));
insert into qa_results values('Missing/empty items, negative/fractional/duplicate quantities, last/zero stock','PASS');
update public.mk_orders set step=4 where id=oid;
failed=false;
begin perform public.mk_cancel_order(oid,tok);exception when others then failed=true;end;
if not failed then raise exception 'QA: collected pickup canceled';end if;
update public.mk_orders set step=3,pickup_ready_at=now()-interval '23 hours 59 minutes' where id=oid;
perform public.mk_catalog();
if (select final_state is not null from public.mk_orders where id=oid) then raise exception 'QA: early pickup expiry';end if;
update public.mk_orders set pickup_ready_at=now()-interval '24 hours' where id=oid;
perform public.mk_catalog();
if (select final_state from public.mk_orders where id=oid)<>'Не забрано' then raise exception 'QA: pickup not expired';end if;
insert into qa_results values('Pickup cancellation boundary and exact 24h expiry','PASS');
v=base||'{"payment":"cod","delivery":{"recipient":"Тест Отримувач","phone":"+380990000002","city":"Київ","point":"Відділення 1","deliveryType":"branch","comment":""}}'::jsonb;
for i in 1..3 loop perform public.mk_create_order(gen_random_uuid(),gen_random_uuid(),v);end loop;
perform pg_temp.reject_order(v);
perform pg_temp.reject_order(jsonb_set(v,'{buyerPhone}','"+380990000003"'));
insert into qa_results values('COD limit includes shared recipient across different buyers','PASS');
if exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('mk_profiles','mk_orders','mk_order_lines','mk_catalog_items','mk_promotions') and not c.relrowsecurity) then raise exception 'QA: RLS disabled';end if;
if has_table_privilege('anon','public.mk_profiles','SELECT') or has_table_privilege('anon','public.mk_orders','SELECT') or has_column_privilege('authenticated','public.mk_orders','access_token','SELECT') or has_table_privilege('authenticated','public.mk_orders','INSERT') then raise exception 'QA: excessive grants';end if;
insert into qa_results values('All tables use RLS; guest reads/writes and authenticated token reads denied','PASS');
end $$;
select * from qa_results;
rollback;


