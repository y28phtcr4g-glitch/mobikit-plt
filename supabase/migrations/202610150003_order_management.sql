begin;
create table public.mk_store_settings(singleton boolean primary key default true check(singleton),live_orders boolean not null default false);
insert into public.mk_store_settings values(true,false);
alter table public.mk_store_settings enable row level security;
revoke all on public.mk_store_settings from public,anon,authenticated;
alter table public.mk_orders add column revision bigint not null default 0;
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
 select count(*) into n from public.mk_orders where payment='cod' and final_state is null and (buyer_phone in (buyer,recipient) or recipient_phone in (buyer,recipient));
 if n>=3 then raise exception 'Для цього номера вже є 3 активні замовлення з післяплатою'; end if;
 end if;
 if coalesce(jsonb_typeof(p_order->'items'),'null')<>'array' or coalesce(jsonb_array_length(p_order->'items'),0) not between 1 and 100 then raise exception 'Кошик порожній або завеликий'; end if;
 if exists(select 1 from jsonb_array_elements(p_order->'items') x group by x->>'id',coalesce(x->>'variantKey','') having count(*)>1) then raise exception 'Об’єднай однакові позиції кошика'; end if;
 for item in select value from jsonb_array_elements(p_order->'items') loop
 if coalesce(item->>'qty','') !~ '^[1-9][0-9]?$' then raise exception 'Некоректна кількість'; end if;
 qty=(item->>'qty')::integer;
 select * into c from public.mk_catalog_items where product_id=item->>'id' and variant_key=coalesce(item->>'variantKey','');
 if not found or c.is_demo=live or not c.published then raise exception 'Товар зараз недоступний'; end if;
 select coalesce(sum(l.qty),0) into reserved from public.mk_order_lines l join public.mk_orders o on o.id=l.order_id where o.final_state is null and l.product_id=c.product_id and l.variant_key=c.variant_key;
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

create or replace function public.mk_admin_catalog_save(p_item jsonb,p_revision bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c public.mk_catalog_items; saved public.mk_catalog_items;
 pid text; vk text; amount numeric; physical integer; reserved bigint;
begin
 -- Serialize against checkout/cancellation/expiry, and hold membership against revocation.
 perform pg_advisory_xact_lock(734091);
 perform 1 from public.mk_admin_members where user_id=auth.uid() and role in ('owner','administrator') for share;
 if not found then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_item is null or jsonb_typeof(p_item)<>'object' or octet_length(p_item::text)>12000 then
 raise exception 'Invalid catalog item' using errcode='22023'; end if;
 if exists(select 1 from jsonb_object_keys(p_item) k where k not in
 ('product_id','variant_key','name','variant','photo','warranty','price','stock','published'))
 or not p_item ?& array['product_id','variant_key','name','variant','photo','warranty','price','stock','published']
 or exists(select 1 from jsonb_each(p_item) e where e.key in
 ('product_id','variant_key','name','variant','photo','warranty') and jsonb_typeof(e.value)<>'string')
 or jsonb_typeof(p_item->'price')<>'number' or jsonb_typeof(p_item->'stock')<>'number'
 or jsonb_typeof(p_item->'published')<>'boolean' then
 raise exception 'Invalid catalog fields' using errcode='22023'; end if;
 pid=p_item->>'product_id'; vk=p_item->>'variant_key';
 if pid !~ '^[a-z0-9][a-z0-9_-]{0,119}$'
 or (vk<>'' and vk !~ '^[a-z0-9][a-z0-9_-]{0,119}$')
 or length(btrim(p_item->>'name')) not between 1 and 200
 or length(p_item->>'variant')>200 or length(p_item->>'warranty')>500
 or length(p_item->>'photo')>2000
 or ((p_item->>'photo')<>'' and (p_item->>'photo') !~ '^https://[^[:space:]"<>\\@]+$')
 or (p_item->>'stock') !~ '^(0|[1-9][0-9]{0,6})$' then
 raise exception 'Invalid catalog fields' using errcode='22023'; end if;
 amount=(p_item->>'price')::numeric; physical=(p_item->>'stock')::integer;
 if amount<0 or amount>9999999999.99 or amount<>round(amount,2) or physical>1000000 then
 raise exception 'Invalid price or stock' using errcode='22023'; end if;
 select * into c from public.mk_catalog_items where product_id=pid and variant_key=vk for update;
 if found then

 if p_revision is null or p_revision<>c.revision then
 raise exception 'Catalog changed; reload before saving' using errcode='40001'; end if;
 else
 if p_revision is not null then raise exception 'Catalog changed; reload before saving' using errcode='40001'; end if;
 if (p_item->>'published')::boolean then raise exception 'Create as draft before publishing' using errcode='22023'; end if;
 end if;
 perform public.mk_expire_pickups();
 select coalesce(sum(l.qty),0) into reserved from public.mk_order_lines l join public.mk_orders o on o.id=l.order_id
 where o.final_state is null and l.product_id=pid and l.variant_key=vk;
 if reserved>0 and physical<reserved+1 then
 raise exception 'Stock must cover reservations and last store unit' using errcode='22023'; end if;
 insert into public.mk_catalog_items(product_id,variant_key,name,variant,photo,warranty,price,stock,is_demo,published,revision)
 values(pid,vk,btrim(p_item->>'name'),p_item->>'variant',p_item->>'photo',p_item->>'warranty',
 amount,physical,(select not live_orders from public.mk_store_settings where singleton),(p_item->>'published')::boolean,0)
 on conflict(product_id,variant_key) do update set
 name=excluded.name,variant=excluded.variant,photo=excluded.photo,warranty=excluded.warranty,
 price=excluded.price,stock=excluded.stock,published=excluded.published,revision=public.mk_catalog_items.revision+1
 returning * into saved;
 return to_jsonb(saved);
end $$;
create or replace function public.mk_storefront() returns jsonb
language plpgsql security definer set search_path='' as $$
declare items jsonb; offers jsonb;
begin
 items=public.mk_catalog();
 select coalesce(jsonb_agg(jsonb_build_object('id',p.product_id,'salePrice',p.sale_price,'published',true,'startAt',p.start_at,'endAt',p.end_at)),'[]'::jsonb)
 into offers from public.mk_promotions p where p.published and exists(select 1 from public.mk_catalog_items c where c.product_id=p.product_id and c.published)
 and (p.start_at is null or p.start_at<=now()) and (p.end_at is null or p.end_at>now());
 return jsonb_build_object('liveOrders',(select live_orders from public.mk_store_settings where singleton),'items',items,'promotions',offers,'categories',(select coalesce(jsonb_agg(to_jsonb(c) order by c.name),'[]'::jsonb) from public.mk_categories c));
end $$;
revoke all on function public.mk_storefront() from public,anon,authenticated;
grant execute on function public.mk_storefront() to anon,authenticated;


create function public.mk_admin_orders() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(734091);
 perform 1 from public.mk_admin_members where user_id=auth.uid() and role in ('owner','administrator') for share;
 if not found then raise exception 'Not authorized' using errcode='42501';end if;
 perform public.mk_expire_pickups();
 return (select coalesce(jsonb_agg(payload||jsonb_build_object('revision',revision,'isDemo',is_demo) order by created_at desc),'[]'::jsonb) from (select * from public.mk_orders order by created_at desc limit 500) o);
end $$;
create function public.mk_admin_order_update(p_id uuid,p_revision bigint,p_action text,p_ttn text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.mk_orders; result jsonb; item record; next_step integer; stamp text=to_char(now() at time zone 'Europe/Kyiv','DD.MM.YY HH24:MI');
begin
 perform pg_advisory_xact_lock(734091);
 perform 1 from public.mk_admin_members where user_id=auth.uid() and role in ('owner','administrator') for share;
 if not found then raise exception 'Not authorized' using errcode='42501';end if;
 perform public.mk_expire_pickups();
 select * into o from public.mk_orders where id=p_id for update;
 if not found then raise exception 'Order not found' using errcode='22023';end if;
 if p_revision is null or p_revision<>o.revision then raise exception 'Order changed' using errcode='40001';end if;
 if o.final_state is not null then raise exception 'Order is closed' using errcode='22023';end if;
 if p_action='ttn' then
  if o.payment<>'cod' or p_ttn is null or p_ttn !~ '^[0-9]{14}$' or o.step>=4 then raise exception 'Invalid tracking number or stage' using errcode='22023';end if;
  update public.mk_orders set payload=payload||jsonb_build_object('ttn',p_ttn,'deliveryStatus','ТТН внесена магазином; статус перевізника не підключений','history',coalesce(payload->'history','[]'::jsonb)||jsonb_build_array(jsonb_build_object('title','Магазин додав ТТН','time',stamp))),revision=revision+1 where id=o.id returning payload||jsonb_build_object('revision',revision,'isDemo',is_demo) into result;
 elsif p_action='cancel' then
  if o.step>=4 then raise exception 'Cannot cancel after handover' using errcode='22023';end if;
  update public.mk_orders set final_state='Скасовано',payload=payload||jsonb_build_object('status','Скасовано магазином','history',coalesce(payload->'history','[]'::jsonb)||jsonb_build_array(jsonb_build_object('title','Скасовано магазином','time',stamp))),revision=revision+1 where id=o.id returning payload||jsonb_build_object('revision',revision,'isDemo',is_demo) into result;
 elsif p_action='return' then
  if o.payment<>'cod' or o.step<>4 then raise exception 'Return only after shipment' using errcode='22023';end if;
  update public.mk_orders set final_state='Повернено',payload=payload||jsonb_build_object('status','Повернення отримано магазином','history',coalesce(payload->'history','[]'::jsonb)||jsonb_build_array(jsonb_build_object('title','Повернення фізично отримано магазином','time',stamp))),revision=revision+1 where id=o.id returning payload||jsonb_build_object('revision',revision,'isDemo',is_demo) into result;
 elsif p_action='next' then
  next_step=o.step+1;
  if next_step>5 or (o.payment='cod' and next_step=4 and coalesce(o.payload->>'ttn','') !~ '^[0-9]{14}$') then raise exception 'Tracking required before handover' using errcode='22023';end if;
  if next_step=5 and not o.is_demo then
   for item in select * from public.mk_order_lines where order_id=o.id loop
    update public.mk_catalog_items set stock=stock-item.qty,revision=revision+1 where product_id=item.product_id and variant_key=item.variant_key and stock>=item.qty;
    if not found then raise exception 'Stock mismatch' using errcode='22023';end if;
   end loop;
  end if;
  update public.mk_orders set step=next_step,final_state=case when next_step=5 then 'Завершено' else null end,
   payload=case when next_step=5 then payload||jsonb_build_object('status',case when payment='pickup' then 'Завершено · видано' else 'Завершено · отримано' end,'history',coalesce(payload->'history','[]'::jsonb)||jsonb_build_array(jsonb_build_object('title','Замовлення завершено','time',stamp))) else payload end,
   revision=revision+1 where id=o.id returning payload||jsonb_build_object('revision',revision,'isDemo',is_demo) into result;
 else raise exception 'Invalid action' using errcode='22023';end if;
 return result;
end $$;
revoke all on function public.mk_admin_orders(),public.mk_admin_order_update(uuid,bigint,text,text) from public,anon,authenticated;
grant execute on function public.mk_admin_orders(),public.mk_admin_order_update(uuid,bigint,text,text) to authenticated;
-- Any update, including customer cancellation and reservation expiry, invalidates old admin forms.
create function public.mk_order_revision() returns trigger language plpgsql set search_path='' as $$ begin new.revision=old.revision+1;return new;end $$;
revoke all on function public.mk_order_revision() from public,anon,authenticated;
create trigger mk_order_revision before update on public.mk_orders for each row execute function public.mk_order_revision();
create or replace function public.mk_admin_promotion_save(p_item jsonb,p_revision bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare old public.mk_promotions; saved public.mk_promotions; amount numeric; starts timestamptz; ends timestamptz;
begin
 perform pg_advisory_xact_lock(734091);
 perform 1 from public.mk_admin_members where user_id=auth.uid() and role in ('owner','administrator') for share;
 if not found then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_item is null or jsonb_typeof(p_item)<>'object' or octet_length(p_item::text)>4000
 or not p_item ?& array['product_id','sale_price','published','start_at','end_at']
 or exists(select 1 from jsonb_object_keys(p_item) k where k not in ('product_id','sale_price','published','start_at','end_at'))
 or jsonb_typeof(p_item->'product_id')<>'string' or jsonb_typeof(p_item->'sale_price')<>'number'
 or jsonb_typeof(p_item->'published')<>'boolean'
 or jsonb_typeof(p_item->'start_at') not in ('string','null') or jsonb_typeof(p_item->'end_at') not in ('string','null') then raise exception 'Invalid promotion' using errcode='22023'; end if;
 amount=(p_item->>'sale_price')::numeric; starts=(p_item->>'start_at')::timestamptz; ends=(p_item->>'end_at')::timestamptz;
 if amount<0 or amount>9999999999.99 or amount<>round(amount,2) or (starts is not null and ends is not null and ends<=starts)
 or not exists(select 1 from public.mk_catalog_items where product_id=p_item->>'product_id') then raise exception 'Invalid promotion' using errcode='22023'; end if;
 select * into old from public.mk_promotions where product_id=p_item->>'product_id' for update;
 if (found and (p_revision is null or p_revision<>old.revision)) or (not found and p_revision is not null) then raise exception 'Promotion changed; reload' using errcode='40001'; end if;
 insert into public.mk_promotions(product_id,sale_price,published,start_at,end_at,revision)
 values(p_item->>'product_id',amount,(p_item->>'published')::boolean,starts,ends,0)
 on conflict(product_id) do update set sale_price=excluded.sale_price,published=excluded.published,start_at=excluded.start_at,end_at=excluded.end_at,revision=public.mk_promotions.revision+1 returning * into saved;
 return to_jsonb(saved);
end $$;
revoke all on function public.mk_admin_promotions(),public.mk_admin_promotion_save(jsonb,bigint) from public,anon,authenticated;
grant execute on function public.mk_admin_promotions(),public.mk_admin_promotion_save(jsonb,bigint) to authenticated;

create or replace function public.mk_admin_catalog_list() returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform pg_advisory_xact_lock(734091);
 perform 1 from public.mk_admin_members where user_id=auth.uid() and role in ('owner','administrator') for share;
 if not found then raise exception 'Not authorized' using errcode='42501'; end if;
 perform public.mk_expire_pickups();
 select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object(
 'reserved',coalesce(r.qty,0),'available',greatest(0,c.stock-coalesce(r.qty,0)),
 'orderable',case when c.published then greatest(0,c.stock-coalesce(r.qty,0)-1) else 0 end
 ) order by c.product_id,c.variant_key),'[]'::jsonb) into result
 from public.mk_catalog_items c left join (
 select l.product_id,l.variant_key,sum(l.qty) qty from public.mk_order_lines l join public.mk_orders o on o.id=l.order_id
 where o.final_state is null group by l.product_id,l.variant_key
 ) r using(product_id,variant_key);
 return result;
end $$;


notify pgrst,'reload schema';
commit;
