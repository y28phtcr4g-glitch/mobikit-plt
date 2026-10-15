begin;
insert into auth.users(id,email) values('00000000-0000-4000-8000-000000000081','editor-owner@example.invalid'),('00000000-0000-4000-8000-000000000082','editor-customer@example.invalid');
insert into public.mk_admin_members(user_id,role) values('00000000-0000-4000-8000-000000000081','owner');
set local role authenticated;
do $$
declare item jsonb='{"product_id":"qa-editor","variant_key":"","name":"QA Product","variant":"","photo":"https://example.invalid/p.jpg","warranty":"90 days","price":123.45,"stock":4,"published":false,"category":"cables","description":"<script>text only</script>"}'; r jsonb; offer jsonb;
begin
 perform set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000082',true);
 begin perform public.mk_admin_product_save(item,null);raise exception 'Customer write accepted';exception when insufficient_privilege then null;end;
 begin perform public.mk_admin_promotions();raise exception 'Customer draft leak';exception when insufficient_privilege then null;end;
 begin perform public.mk_admin_promotion_save('{}',null);raise exception 'Customer promo write';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000081',true);
 r=public.mk_admin_product_save(item,null);
 if r->>'description'<>item->>'description' or r->>'category'<>'cables' then raise exception 'Metadata lost';end if;
 if exists(select 1 from jsonb_array_elements(public.mk_storefront()->'items') x where x->>'product_id'='qa-editor') then raise exception 'Draft leaked';end if;
 begin perform public.mk_admin_product_save(item||'{"category":"invalid"}',0);raise exception 'Invalid category accepted';exception when invalid_parameter_value then null;end;
 begin perform public.mk_admin_product_save(item||jsonb_build_object('description',repeat('x',4001)),0);raise exception 'Oversize description accepted';exception when invalid_parameter_value then null;end;
 r=public.mk_admin_product_save(item||'{"published":true,"price":140}',0);
 begin perform public.mk_admin_product_save(item,0);raise exception 'Stale edit accepted';exception when serialization_failure then null;end;
 if not exists(select 1 from jsonb_array_elements(public.mk_storefront()->'items') x where x->>'product_id'='qa-editor' and x->>'price'='140.00') then raise exception 'Published edit absent';end if;
 offer='{"product_id":"qa-editor","sale_price":99.50,"published":true,"start_at":null,"end_at":null}';
 r=public.mk_admin_promotion_save(offer,null);
 if not exists(select 1 from jsonb_array_elements(public.mk_storefront()->'promotions') x where x->>'id'='qa-editor' and (x->>'salePrice')::numeric=99.50) then raise exception 'Promotion absent';end if;
 begin perform public.mk_admin_promotion_save(offer,null);raise exception 'Stale promo accepted';exception when serialization_failure then null;end;
 begin perform public.mk_admin_promotion_save(offer||'{"sale_price":-1}',0);raise exception 'Negative price';exception when invalid_parameter_value then null;end;
 perform public.mk_admin_promotion_save(offer||'{"published":false}',0);
 if exists(select 1 from jsonb_array_elements(public.mk_storefront()->'promotions') x where x->>'id'='qa-editor') then raise exception 'Hidden promotion leaked';end if;
 perform public.mk_admin_product_save(item||'{"published":false}',1);
 if exists(select 1 from jsonb_array_elements(public.mk_storefront()->'items') x where x->>'product_id'='qa-editor') then raise exception 'Hidden item leaked';end if;
end $$;
reset role;
set local role anon;
do $$ begin
 perform public.mk_storefront();
 begin perform public.mk_admin_promotions();raise exception 'Anonymous admin access';exception when insufficient_privilege then null;end;
end $$;
rollback;
