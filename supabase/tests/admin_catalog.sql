-- Disposable database only. All users, inventory and orders roll back.
begin;
insert into auth.users(id,email,raw_user_meta_data) values
('00000000-0000-4000-8000-000000000091','qa-owner@example.invalid','{}'),
('00000000-0000-4000-8000-000000000092','qa-admin@example.invalid','{}'),
('00000000-0000-4000-8000-000000000093','qa-seller@example.invalid','{}'),
('00000000-0000-4000-8000-000000000094','qa-customer@example.invalid','{"role":"owner"}');
insert into public.mk_admin_members(user_id,role) values
('00000000-0000-4000-8000-000000000091','owner'),
('00000000-0000-4000-8000-000000000092','administrator'),
('00000000-0000-4000-8000-000000000093','seller');
create function pg_temp.item(vk text default 'black',stock integer default 5,published boolean default false,price numeric default 100) returns jsonb
language sql as $$
select jsonb_build_object('product_id','qa-catalog','variant_key',vk,'name','QA Product',
'variant',vk,'photo','','warranty','QA only','price',price,'stock',stock,'published',published)
$$;
create function pg_temp.reject_save(item jsonb,rev bigint,expected text) returns void language plpgsql as $$
begin
 begin perform public.mk_admin_catalog_save(item,rev);
 exception when others then
 if sqlstate=expected then return; end if;
 raise exception 'Wrong SQLSTATE: %, expected %: %',sqlstate,expected,sqlerrm;
 end;
 raise exception 'Unexpected catalog save success';
end $$;
set local role authenticated;
do $$
declare uid text; r jsonb; bad jsonb;
begin
 foreach uid in array array['00000000-0000-4000-8000-000000000093','00000000-0000-4000-8000-000000000094',''] loop
 perform set_config('request.jwt.claim.sub',uid,true);
 begin perform public.mk_admin_catalog_list(); raise exception 'Draft leak';
 exception when insufficient_privilege then null; end;
 perform pg_temp.reject_save(pg_temp.item(),null,'42501');
 end loop;
 foreach uid in array array['00000000-0000-4000-8000-000000000091','00000000-0000-4000-8000-000000000092'] loop
 perform set_config('request.jwt.claim.sub',uid,true);
 -- Each role can create a product variant and publish it with an explicit revision.
 r=public.mk_admin_catalog_save(pg_temp.item(uid),null);
 if (r->>'revision')::bigint<>0 or (r->>'published')::boolean then raise exception 'Invalid draft'; end if;
 r=public.mk_admin_catalog_save(pg_temp.item(uid,5,true,123.45),0);
 if (r->>'revision')::bigint<>1 or (r->>'price')::numeric<>123.45 then raise exception 'Update failed'; end if;
 perform pg_temp.reject_save(pg_temp.item(uid),0,'40001');
 perform pg_temp.reject_save(pg_temp.item(uid),null,'40001');
 end loop;
 r=public.mk_admin_catalog_save(pg_temp.item('white'),null);
 r=public.mk_admin_catalog_save(pg_temp.item(''),null);
 r=public.mk_admin_catalog_save(pg_temp.item(),null);
 perform pg_temp.reject_save(pg_temp.item(),null,'40001');
 perform pg_temp.reject_save(pg_temp.item('missing'),0,'40001');
 perform pg_temp.reject_save(pg_temp.item('new',5,true),null,'22023');
 foreach bad in array array[
 null::jsonb,'null'::jsonb,'[]'::jsonb,'{}'::jsonb,
 pg_temp.item()-'stock',pg_temp.item()||'{"stock":null}',
 pg_temp.item()||'{"price":"100"}',pg_temp.item()||'{"published":null}',
 pg_temp.item()||'{"is_demo":false}',pg_temp.item()||'{"role":"owner"}',
 pg_temp.item()||'{"name":null}',pg_temp.item()||'{"name":"  "}',
 pg_temp.item()||'{"product_id":"../bad"}',pg_temp.item()||'{"stock":1.5}',
 pg_temp.item()||'{"stock":-1}',pg_temp.item()||'{"stock":1000001}',
 pg_temp.item()||'{"price":-1}',pg_temp.item()||'{"price":1.001}',
 pg_temp.item()||'{"price":10000000000}',pg_temp.item()||'{"photo":"javascript:alert(1)"}',
 pg_temp.item()||'{"photo":"https://user:pass@example.com/a.png"}'
 ] loop perform pg_temp.reject_save(bad,0,'22023'); end loop;
 r=public.mk_admin_catalog_save(pg_temp.item('black',5,true),0);
 -- Direct table access remains closed even for owner/admin.
 begin perform 1 from public.mk_catalog_items; raise exception 'Direct SELECT allowed';
 exception when insufficient_privilege then null; end;
 begin update public.mk_catalog_items set stock=999; raise exception 'Direct UPDATE allowed';
 exception when insufficient_privilege then null; end;
 begin insert into public.mk_admin_members(user_id,role) values(auth.uid(),'owner'); raise exception 'Self promotion';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
create temporary table qa_catalog_order(payload jsonb,request_id uuid,token uuid);
grant all on qa_catalog_order to anon,authenticated;
set local role anon;
select set_config('request.jwt.claim.sub','',true);
do $$
declare v jsonb; req uuid=gen_random_uuid(); tok uuid=gen_random_uuid();
begin
 begin perform public.mk_admin_catalog_list(); raise exception 'Anon list allowed';
 exception when insufficient_privilege then null; end;
 perform pg_temp.reject_save(pg_temp.item(),1,'42501');
 v=public.mk_create_order(req,tok,'{"payment":"pickup","buyerName":"Тест Каталог","buyerPhone":"+380990000091","items":[{"id":"qa-catalog","variantKey":"black","qty":3,"unitPrice":1}]}');
 if (v->>'total')::numeric<>300 then raise exception 'Server price ignored'; end if;
 insert into qa_catalog_order values(v,req,tok);
 -- 5 physical minus 3 reserved minus last display unit allows only 1 further unit.
 begin
 perform public.mk_create_order(gen_random_uuid(),gen_random_uuid(),'{"payment":"pickup","buyerName":"Тест Каталог","buyerPhone":"+380990000091","items":[{"id":"qa-catalog","variantKey":"black","qty":2}]}');
 raise exception 'Oversold last unit';
 exception when raise_exception then if sqlerrm='Oversold last unit' then raise; end if; end;
end $$;
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000092',true);
do $$
declare row jsonb; r jsonb;
begin
 select value into row from jsonb_array_elements(public.mk_admin_catalog_list()) where value->>'product_id'='qa-catalog' and value->>'variant_key'='black';
 if row->>'reserved'<>'3' or row->>'available'<>'2' or row->>'orderable'<>'1' then raise exception 'Reservation counts wrong: %',row; end if;
 perform pg_temp.reject_save(pg_temp.item('black',3),1,'22023');
 -- Exact reservation + display-unit boundary accepted; hide with active order safely.
 r=public.mk_admin_catalog_save(pg_temp.item('black',4,false,200),1);

 if exists(select 1 from jsonb_array_elements(public.mk_catalog()) where value->>'product_id'='qa-catalog' and value->>'variant_key'='black') then raise exception 'Hidden item leaked'; end if;
end $$;
reset role;
set local role anon;
select set_config('request.jwt.claim.sub','',true);
do $$
declare before jsonb; replay jsonb;
begin
 select payload into before from qa_catalog_order;
 select public.mk_create_order(request_id,token,'{}') into replay from qa_catalog_order;
 if replay<>before then raise exception 'Replay changed after edit'; end if;
 begin
 perform public.mk_create_order(gen_random_uuid(),gen_random_uuid(),'{"payment":"pickup","buyerName":"Тест Каталог","buyerPhone":"+380990000091","items":[{"id":"qa-catalog","variantKey":"black","qty":1}]}');
 raise exception 'Hidden checkout succeeded';
 exception when raise_exception then if sqlerrm='Hidden checkout succeeded' then raise; end if; end;
 perform public.mk_cancel_order((payload->>'serverId')::uuid,token) from qa_catalog_order;
end $$;
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000092',true);
do $$
begin
 if not exists(select 1 from jsonb_array_elements(public.mk_admin_catalog_list()) where value->>'product_id'='qa-catalog' and value->>'variant_key'='white' and value->>'stock'='5' and value->>'revision'='0' and value->>'reserved'='0') then raise exception 'Sibling variant changed'; end if;
 -- Canceled reservation releases stock; zero-stock publication is allowed, never orderable.
 perform public.mk_admin_catalog_save(pg_temp.item('black',0,true),2);
 if not exists(select 1 from jsonb_array_elements(public.mk_catalog()) where value->>'product_id'='qa-catalog' and value->>'variant_key'='black' and value->>'available'='0') then raise exception 'Zero stock publication missing'; end if;
end $$;
reset role;
-- Expired pickups release reservations before stock validation.
update public.mk_orders set final_state=null,step=3,pickup_ready_at=now()-interval '24 hours'
where id in(select (payload->>'serverId')::uuid from qa_catalog_order);
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000092',true);
select public.mk_admin_catalog_save(pg_temp.item('black',0,false),3);
reset role;
-- Owner can edit live inventory; browser cannot alter its mode.
update public.mk_catalog_items set is_demo=false where product_id='qa-catalog' and variant_key='black';
set local role authenticated;
select public.mk_admin_catalog_save(pg_temp.item(),4);
reset role;
delete from public.mk_admin_members where user_id='00000000-0000-4000-8000-000000000092';
set local role authenticated;
do $$
begin
 begin perform public.mk_admin_catalog_list(); raise exception 'Revoked role read';
 exception when insufficient_privilege then null; end;
 perform pg_temp.reject_save(pg_temp.item(),4,'42501');
end $$;
reset role;
rollback;
