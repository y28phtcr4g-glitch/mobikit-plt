begin;
insert into auth.users(id,email) values('00000000-0000-4000-8000-000000000095','orders-owner@example.invalid'),('00000000-0000-4000-8000-000000000096','orders-customer@example.invalid');
insert into public.mk_admin_members(user_id,role) values('00000000-0000-4000-8000-000000000095','owner');
update public.mk_store_settings set live_orders=true;
insert into public.mk_catalog_items(product_id,variant_key,name,price,stock,is_demo,published) values('qa-live','','Live Product',150,8,false,true);
select set_config('request.jwt.claim.sub','',true);
set local role anon;
do $$ declare o jsonb; begin
 o=public.mk_create_order('00000000-0000-4000-8000-000000000097','00000000-0000-4000-8000-000000000098','{"payment":"pickup","buyerName":"Тест Покупець","buyerPhone":"+380931234567","items":[{"id":"qa-live","qty":2}]}');
 if (o->>'isDemo')::boolean or (o->>'total')::numeric<>300 then raise exception 'Live checkout failed';end if;
 perform set_config('qa.order',o->>'serverId',true);
 begin perform public.mk_admin_orders();raise exception 'Anonymous orders leak';exception when insufficient_privilege then null;end;
end $$;
reset role;
set local role authenticated;
do $$ declare o jsonb; before_stock integer; id uuid=current_setting('qa.order')::uuid; rev bigint=0; begin
 perform set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000096',true);
 begin perform public.mk_admin_orders();raise exception 'Customer orders leak';exception when insufficient_privilege then null;end;
 begin perform public.mk_admin_order_update(id,0,'next');raise exception 'Customer write';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000095',true);
 if not exists(select 1 from jsonb_array_elements(public.mk_admin_orders()) x where x->>'serverId'=id::text) then raise exception 'Owner cannot see order';end if;
 o=public.mk_admin_order_update(id,rev,'next');rev=(o->>'revision')::bigint;
 begin perform public.mk_admin_order_update(id,0,'next');raise exception 'Stale update';exception when serialization_failure then null;end;
 for i in 2..5 loop o=public.mk_admin_order_update(id,rev,'next');rev=(o->>'revision')::bigint;end loop;
 if o->>'finalState'<>'Завершено' then raise exception 'Order not closed';end if;
 begin perform public.mk_admin_order_update(id,rev,'next');raise exception 'Double complete';exception when invalid_parameter_value then null;end;
end $$;
reset role;
do $$ begin if (select stock from public.mk_catalog_items where product_id='qa-live')<>6 then raise exception 'Stock not deducted exactly once';end if;end $$;
-- Server tracking validation and released reservations on cancellation.
select set_config('request.jwt.claim.sub','',true);
set local role anon;
do $$ declare o jsonb;begin
 o=public.mk_create_order('00000000-0000-4000-8000-000000000099','00000000-0000-4000-8000-000000000100','{"payment":"cod","buyerName":"Тест Покупець","buyerPhone":"+380931234567","delivery":{"recipient":"Тест Покупець","phone":"+380931234567","city":"Полтава","point":"1","deliveryType":"branch"},"items":[{"id":"qa-live","qty":1}]}');perform set_config('qa.order',o->>'serverId',true);
end $$;
reset role;
set local role authenticated;
do $$ declare o jsonb; id uuid=current_setting('qa.order')::uuid;rev bigint=0;begin
 perform set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000095',true);
 for i in 1..3 loop o=public.mk_admin_order_update(id,rev,'next');rev=(o->>'revision')::bigint;end loop;
 begin perform public.mk_admin_order_update(id,rev,'next');raise exception 'Shipped without tracking';exception when invalid_parameter_value then null;end;
 begin perform public.mk_admin_order_update(id,rev,'ttn','abc');raise exception 'Bad tracking';exception when invalid_parameter_value then null;end;
 o=public.mk_admin_order_update(id,rev,'ttn','20400000000000');rev=(o->>'revision')::bigint;
 o=public.mk_admin_order_update(id,rev,'next');rev=(o->>'revision')::bigint;
 begin perform public.mk_admin_order_update(id,rev,'cancel');raise exception 'Cancelled after shipment';exception when invalid_parameter_value then null;end;
 o=public.mk_admin_order_update(id,rev,'return');if o->>'finalState'<>'Повернено' then raise exception 'Return failed';end if;
end $$;
reset role;
do $$ begin if (select stock from public.mk_catalog_items where product_id='qa-live')<>6 then raise exception 'Returned unsold stock changed';end if;end $$;
rollback;
