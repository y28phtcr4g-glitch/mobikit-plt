begin;
insert into auth.users(id,email) values('00000000-0000-4000-8000-000000000081','visibility-owner@example.invalid'),('00000000-0000-4000-8000-000000000082','visibility-customer@example.invalid');
insert into public.mk_admin_members(user_id,role) values('00000000-0000-4000-8000-000000000081','owner');
insert into public.mk_catalog_items(product_id,variant_key,name,variant,photo,warranty,price,stock,is_demo,published,category,description) values('qa-hidden','','Visibility item','','','',100,5,true,true,'cables','Description');
set local role authenticated;
do $$ declare r jsonb; result jsonb; begin
 perform set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000082',true);
 begin perform public.mk_admin_category_visibility('cables',true,0);raise exception 'Customer hid category';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000081',true);
 r=public.mk_admin_category_visibility('cables',true,0);
 if r->>'hidden'<>'true' then raise exception 'Hide failed';end if;
 begin perform public.mk_admin_category_visibility('cables',false,0);raise exception 'Stale revision accepted';exception when serialization_failure then null;end;
 result=public.mk_storefront();
 if not exists(select 1 from jsonb_array_elements(result->'categories') c where c->>'id'='cables' and (c->>'hidden')::boolean) then raise exception 'Owner cannot restore';end if;
end $$;
reset role;
set local role anon;
select set_config('request.jwt.claim.sub','',true);
do $$ declare result jsonb; begin
 result=public.mk_storefront();
 if exists(select 1 from jsonb_array_elements(result->'categories') c where c->>'id'='cables') then raise exception 'Category leaked';end if;
 if exists(select 1 from jsonb_array_elements(public.mk_catalog()) c where c->>'product_id'='qa-hidden') then raise exception 'Product leaked';end if;
 begin perform public.mk_admin_category_visibility('cables',false,1);raise exception 'Anon toggle';exception when insufficient_privilege then null;end;
 begin
 perform public.mk_create_order(gen_random_uuid(),gen_random_uuid(),'{"payment":"pickup","buyerName":"Тест Покупець","buyerPhone":"+380931234567","items":[{"id":"qa-hidden","qty":1}]}');
 raise exception 'Hidden product ordered';
 exception when others then if sqlerrm not like '%Товар зараз недоступний%' then raise;end if;end;
end $$;
reset role;
do $$ begin
 if not exists(select 1 from public.mk_catalog_items where product_id='qa-hidden' and published and stock=5) then raise exception 'Product data modified';end if;
end $$;
set local role authenticated;
do $$ begin
 perform set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000081',true);
 perform public.mk_admin_category_visibility('cables',false,1);
 if not exists(select 1 from jsonb_array_elements(public.mk_catalog()) c where c->>'product_id'='qa-hidden') then raise exception 'Restore failed';end if;
end $$;
rollback;

