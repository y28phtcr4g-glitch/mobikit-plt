begin;
alter table public.mk_catalog_items add column if not exists published boolean not null default false;
update public.mk_catalog_items set published=(product_id in ('case-magsafe','case-gleam-magnetic','hoco-h86-dragon','baseus-gravity-car-mount','camera-a26','camera-q5','printer-d7-rabbit','walker-wts67','proove-dreamer','proove-mello','remax-ap10','borofone-bg100','xo-m8-pro','xo-watch4','hy300','hoco-dt1','aimb-g1','hoco-k24-gimbal','mj261','rechargeable-light-35','baseus-fm11','proove-hoodman','remax-rpp565','walker-wh43-33w','proove-rapid-20w','proove-nova-10w','speaker-walker-wsp750','fan-hoco-hx60','fan-baseus-gotrip-dt1','cable-walker-power-silicone-100w','cable-baseus-rapid-charge'));
create or replace function public.mk_catalog() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform pg_advisory_xact_lock(734091);
 perform public.mk_expire_pickups();
 select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('available',greatest(0,c.stock-coalesce(r.reserved,0)))),'[]'::jsonb) into result
 from public.mk_catalog_items c left join (
 select l.product_id,l.variant_key,sum(l.qty)::integer reserved from public.mk_order_lines l join public.mk_orders o on o.id=l.order_id where o.final_state is null group by l.product_id,l.variant_key
 ) r on r.product_id=c.product_id and r.variant_key=c.variant_key where c.published;
 return result;
end $$;
create or replace function public.mk_create_order(p_request_id uuid,p_access_token uuid,p_order jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare existing public.mk_orders; item jsonb; c public.mk_catalog_items; qty integer; reserved integer; n integer;
 buyer text; recipient text; buyer_name text; delivery jsonb; kind text; total numeric=0; unit numeric; items jsonb='[]';
 result jsonb; new_id uuid=gen_random_uuid(); stamp text=to_char(now() at time zone 'Europe/Kyiv','DD.MM.YY HH24:MI');
 profile public.mk_profiles; uid uuid=auth.uid();
begin
 if p_request_id is null or p_access_token is null or jsonb_typeof(p_order)<>'object' or octet_length(p_order::text)>30000 then raise exception 'Некоректний запит'; end if;
 perform pg_advisory_xact_lock(734091);
 perform public.mk_expire_pickups();
 select * into existing from public.mk_orders where request_id=p_request_id;
 if found then
 if existing.user_id is not distinct from uid and existing.access_token=p_access_token then return existing.payload; end if;
 raise exception 'Повторний запит не належить цьому клієнту';
 end if;
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
 select count(*) into n from public.mk_orders where payment='cod' and final_state is null and (buyer_phone in (buyer,recipient) or recipient_phone in (buyer,recipient));
 if n>=3 then raise exception 'Для цього номера вже є 3 активні замовлення з післяплатою'; end if;
 end if;
 if coalesce(jsonb_typeof(p_order->'items'),'null')<>'array' or coalesce(jsonb_array_length(p_order->'items'),0) not between 1 and 100 then raise exception 'Кошик порожній або завеликий'; end if;
 if exists(select 1 from jsonb_array_elements(p_order->'items') x group by x->>'id',coalesce(x->>'variantKey','') having count(*)>1) then raise exception 'Об’єднай однакові позиції кошика'; end if;
 for item in select value from jsonb_array_elements(p_order->'items') loop
 if coalesce(item->>'qty','') !~ '^[1-9][0-9]?$' then raise exception 'Некоректна кількість'; end if;
 qty=(item->>'qty')::integer;
 select * into c from public.mk_catalog_items where product_id=item->>'id' and variant_key=coalesce(item->>'variantKey','');
 if not found or not c.is_demo or not c.published then raise exception 'Товар не доступний у демокаталозі'; end if;
 select coalesce(sum(l.qty),0) into reserved from public.mk_order_lines l join public.mk_orders o on o.id=l.order_id where o.final_state is null and l.product_id=c.product_id and l.variant_key=c.variant_key;
 if qty>c.stock-reserved-1 then raise exception 'Залишок змінився. Остання одиниця залишається в магазині'; end if;
 unit=c.price;
 select sale_price into unit from public.mk_promotions where product_id=c.product_id and published and (start_at is null or start_at<=now()) and (end_at is null or end_at>now());
 if not found then unit=c.price; end if;
 total=total+unit*qty;
 items=items||jsonb_build_array(jsonb_build_object('id',c.product_id,'variantKey',c.variant_key,'qty',qty,'name',c.name,'photo',c.photo,'variant',c.variant,'unitPrice',unit,'warranty',c.warranty));
 end loop;
 result=jsonb_build_object('id','MK-'||upper(replace(new_id::text,'-','')),'serverId',new_id,'date',stamp,'createdAt',now(),'snapshotVersion',1,
 'total',total,'buyerPhone',buyer,'ownerKey',coalesce(uid::text,'guest'),'items',items,'delivery',delivery,'payment',kind,'isDemo',true,
 'pickupHoldHours',case when kind='pickup' then 24 else null end,'step',0,'ttn',null,'deliveryStatus',null,'status','🟠 Очікує підтвердження',
 'paymentStatus',case when kind='cod' then 'Післяплата при отриманні' else 'Оплата в магазині' end,
 'history',jsonb_build_array(jsonb_build_object('title','Замовлення створено','time',stamp),jsonb_build_object('title',case when kind='cod' then 'Нова пошта · післяплата' else 'Самовивіз · оплата в магазині' end,'time',stamp)));
 insert into public.mk_orders(id,user_id,request_id,access_token,buyer_phone,recipient_phone,payment,payload) values(new_id,uid,p_request_id,p_access_token,buyer,coalesce(recipient,buyer),kind,result);
 for item in select value from jsonb_array_elements(items) loop
 insert into public.mk_order_lines values(new_id,item->>'id',item->>'variantKey',(item->>'qty')::integer);
 end loop;
 return result;
end $$;

commit;


