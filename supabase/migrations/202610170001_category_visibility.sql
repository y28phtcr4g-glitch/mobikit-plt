begin;
alter table public.mk_categories add column hidden boolean not null default false, add column revision bigint not null default 0;
create function public.mk_admin_category_visibility(p_id text,p_hidden boolean,p_revision bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare saved public.mk_categories;
begin
 perform pg_advisory_xact_lock(734091);
 perform 1 from public.mk_admin_members where user_id=auth.uid() and role in ('owner','administrator') for share;
 if not found then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_hidden is null or p_revision is null then raise exception 'Invalid visibility' using errcode='22023'; end if;
 select * into saved from public.mk_categories where id=p_id for update;
 if not found then raise exception 'Category not found' using errcode='22023'; end if;
 if saved.revision<>p_revision then raise exception 'Category changed' using errcode='40001'; end if;
 update public.mk_categories set hidden=p_hidden,revision=revision+1 where id=p_id returning * into saved;
 return to_jsonb(saved);
end $$;
revoke all on function public.mk_admin_category_visibility(text,boolean,bigint) from public,anon,authenticated;
grant execute on function public.mk_admin_category_visibility(text,boolean,bigint) to authenticated;
create or replace function public.mk_catalog() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform pg_advisory_xact_lock(734091);
 perform public.mk_expire_pickups();
 select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('available',greatest(0,c.stock-coalesce(r.reserved,0)))),'[]'::jsonb) into result
 from public.mk_catalog_items c left join (
 select l.product_id,l.variant_key,sum(l.qty)::integer reserved from public.mk_order_lines l join public.mk_orders o on o.id=l.order_id where o.final_state is null and o.is_demo=(select not live_orders from public.mk_store_settings where singleton) group by l.product_id,l.variant_key
 ) r on r.product_id=c.product_id and r.variant_key=c.variant_key where c.published and not exists(select 1 from public.mk_categories k where k.id=c.category and k.hidden);
 return result;
end $$;


create or replace function public.mk_create_order(p_request_id uuid,p_access_token uuid,p_order jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare existing public.mk_orders; item jsonb; c public.mk_catalog_items; qty integer; reserved integer; n integer;
 buyer text; recipient text; buyer_name text; delivery jsonb; kind text; total numeric=0; unit numeric; items jsonb='[]';
 result jsonb; new_id uuid=gen_random_uuid(); stamp text=to_char(now() at time zone 'Europe/Kyiv','DD.MM.YY HH24:MI');
 profile public.mk_profiles; uid uuid=auth.uid(); live boolean;
begin
 if p_request_id is null or p_access_token is null or jsonb_typeof(p_order)<>'object' or octet_length(p_order::text)>30000 then raise exception 'Некоректний запит'; end if;
 perform pg_advisory_xact_lock(734091);
 perform public.mk_expire_pickups();
 select * into existing from public.mk_orders where request_id=p_request_id;
 if found then
 if existing.user_id is not distinct from uid and existing.access_token=p_access_token then return existing.payload; end if;
 raise exception 'Повторний запит не належить цьому клієнту';
 end if;
 select live_orders into live from public.mk_store_settings where singleton;
 kind=p_order->>'payment';
 if kind is null or kind not in ('pickup','cod') then raise exception 'Обери спосіб отримання'; end if;
 delivery=p_order->'delivery';
 buyer_name=btrim(p_order->>'buyerName');
 buyer=public.mk_phone(p_order->>'buyerPhone');
 if uid is not null then
 select * into profile from public.mk_profiles where user_id=uid;
 if not found then raise exception 'Спочатку заповни профіль'; end if;
 buyer_name=profile.name;buyer=profile.phone;
 end if;
 if not public.mk_full_name(buyer_name) or buyer !~ '^\+380[0-9]{9}$' then raise exception 'Потрібні ім’я, прізвище та український номер'; end if;
 if kind='pickup' then delivery=jsonb_build_object('pickup',true,'recipient',buyer_name,'phone',buyer);
 else
 recipient=public.mk_phone(delivery->>'phone');
 if not public.mk_full_name(delivery->>'recipient') or recipient !~ '^\+380[0-9]{9}$'
 or coalesce(length(btrim(delivery->>'city')),0) not between 1 and 120 or coalesce(length(btrim(delivery->>'point')),0) not between 1 and 160
 or coalesce(delivery->>'deliveryType','') not in ('branch','locker') or coalesce(length(delivery->>'comment'),0)>1000 then raise exception 'Перевір дані Нової пошти'; end if;
 delivery=delivery||jsonb_build_object('phone',recipient);
 select count(*) into n from public.mk_orders where payment='cod' and final_state is null and is_demo=not live and (buyer_phone in (buyer,recipient) or recipient_phone in (buyer,recipient));
 if n>=3 then raise exception 'Для цього номера вже є 3 активні замовлення з післяплатою'; end if;
 end if;
 if coalesce(jsonb_typeof(p_order->'items'),'null')<>'array' or coalesce(jsonb_array_length(p_order->'items'),0) not between 1 and 100 then raise exception 'Кошик порожній або завеликий'; end if;
 if exists(select 1 from jsonb_array_elements(p_order->'items') x group by x->>'id',coalesce(x->>'variantKey','') having count(*)>1) then raise exception 'Об’єднай однакові позиції кошика'; end if;
 for item in select value from jsonb_array_elements(p_order->'items') loop
 if coalesce(item->>'qty','') !~ '^[1-9][0-9]?$' then raise exception 'Некоректна кількість'; end if;
 qty=(item->>'qty')::integer;
 select * into c from public.mk_catalog_items where product_id=item->>'id' and variant_key=coalesce(item->>'variantKey','');
 if not found or c.is_demo=live or not c.published or exists(select 1 from public.mk_categories k where k.id=c.category and k.hidden) then raise exception 'Товар зараз недоступний'; end if;
 select coalesce(sum(l.qty),0) into reserved from public.mk_order_lines l join public.mk_orders o on o.id=l.order_id where o.final_state is null and o.is_demo=(select not live_orders from public.mk_store_settings where singleton) and l.product_id=c.product_id and l.variant_key=c.variant_key;
 if qty>c.stock-reserved-1 then raise exception 'Залишок змінився. Остання одиниця залишається в магазині'; end if;
 unit=c.price;
 select sale_price into unit from public.mk_promotions where product_id=c.product_id and published and (start_at is null or start_at<=now()) and (end_at is null or end_at>now());
 if not found then unit=c.price; end if;
 total=total+unit*qty;
 items=items||jsonb_build_array(jsonb_build_object('id',c.product_id,'variantKey',c.variant_key,'qty',qty,'name',c.name,'photo',c.photo,'variant',c.variant,'unitPrice',unit,'warranty',c.warranty));
 end loop;
 result=jsonb_build_object('id','MK-'||upper(replace(new_id::text,'-','')),'serverId',new_id,'date',stamp,'createdAt',now(),'snapshotVersion',1,
 'total',total,'buyerPhone',buyer,'ownerKey',coalesce(uid::text,'guest'),'items',items,'delivery',delivery,'payment',kind,'isDemo',not live,
 'pickupHoldHours',case when kind='pickup' then 24 else null end,'step',0,'ttn',null,'deliveryStatus',null,'status','🟠 Очікує підтвердження',
 'paymentStatus',case when kind='cod' then 'Післяплата при отриманні' else 'Оплата в магазині' end,
 'history',jsonb_build_array(jsonb_build_object('title','Замовлення створено','time',stamp),jsonb_build_object('title',case when kind='cod' then 'Нова пошта · післяплата' else 'Самовивіз · оплата в магазині' end,'time',stamp)));
 insert into public.mk_orders(id,user_id,request_id,access_token,buyer_phone,recipient_phone,payment,payload,is_demo) values(new_id,uid,p_request_id,p_access_token,buyer,coalesce(recipient,buyer),kind,result,not live);
 for item in select value from jsonb_array_elements(items) loop
 insert into public.mk_order_lines values(new_id,item->>'id',item->>'variantKey',(item->>'qty')::integer);
 end loop;
 return result;
end $$;

create or replace function public.mk_storefront() returns jsonb
language plpgsql security definer set search_path='' as $$
declare items jsonb; offers jsonb; categories jsonb;
begin
 items=public.mk_catalog();
 select coalesce(jsonb_agg(jsonb_build_object('id',p.product_id,'salePrice',p.sale_price,'published',true,'startAt',p.start_at,'endAt',p.end_at)),'[]'::jsonb)
 into offers from public.mk_promotions p where p.published and exists(select 1 from jsonb_array_elements(items) c where c->>'product_id'=p.product_id)
 and (p.start_at is null or p.start_at<=now()) and (p.end_at is null or p.end_at>now());
 select coalesce(jsonb_agg(to_jsonb(c) order by c.name),'[]'::jsonb) into categories from public.mk_categories c
 where not c.hidden or coalesce(public.mk_admin_role() in ('owner','administrator'),false);
 return jsonb_build_object('items',items,'promotions',offers,'categories',categories);
end $$;
notify pgrst,'reload schema';
commit;

