-- MOBIKIT: isolated demo catalogue; never seeds real stock or prices.
begin;
create table if not exists public.mk_profiles (
 user_id uuid primary key references auth.users(id) on delete cascade,
 name text not null default '' check (length(name)<=120),
 phone text not null default '' check (phone='' or phone ~ '^\+380[0-9]{9}$'),
 birthday date,
 avatar_cat text not null default '😼' check (length(avatar_cat)<=16),
 avatar_image text not null default '' check (length(avatar_image)<=2100000),
 favorites jsonb not null default '[]' check (jsonb_typeof(favorites)='array' and jsonb_array_length(favorites)<=500),
 waiting jsonb not null default '[]' check (jsonb_typeof(waiting)='array' and jsonb_array_length(waiting)<=500),
 updated_at timestamptz not null default now()
);
create table if not exists public.mk_catalog_items (
 product_id text not null, variant_key text not null default '', name text not null, variant text not null default '',
 photo text not null default '', warranty text not null default '', price numeric(12,2) not null check(price>=0),
 stock integer not null check(stock>=0), is_demo boolean not null default true,
 primary key(product_id,variant_key)
);
create table if not exists public.mk_promotions (
 product_id text primary key, sale_price numeric(12,2) not null check(sale_price>=0),
 published boolean not null default false, start_at timestamptz, end_at timestamptz,
 check(start_at is null or end_at is null or end_at>start_at)
);
create table if not exists public.mk_orders (
 id uuid primary key default gen_random_uuid(), user_id uuid references auth.users(id),
 request_id uuid not null unique, access_token uuid not null, created_at timestamptz not null default now(),
 buyer_phone text not null, recipient_phone text not null, payment text not null check(payment in ('pickup','cod')),
 step integer not null default 0 check(step between 0 and 5), final_state text,
 pickup_ready_at timestamptz, payload jsonb not null, is_demo boolean not null default true
);
create index if not exists mk_orders_owner on public.mk_orders(user_id,created_at desc);
create index if not exists mk_orders_cod on public.mk_orders(buyer_phone,recipient_phone) where payment='cod' and final_state is null;
create table if not exists public.mk_order_lines (
 order_id uuid references public.mk_orders(id) on delete cascade, product_id text not null, variant_key text not null,
 qty integer not null check(qty>0 and qty<=98), primary key(order_id,product_id,variant_key),
 foreign key(product_id,variant_key) references public.mk_catalog_items(product_id,variant_key)
);
alter table public.mk_profiles enable row level security;
alter table public.mk_catalog_items enable row level security;
alter table public.mk_promotions enable row level security;
alter table public.mk_orders enable row level security;
alter table public.mk_order_lines enable row level security;
do $$ begin
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='mk_profiles' and policyname='mk_profile_owner') then
 create policy mk_profile_owner on public.mk_profiles for all to authenticated using ((select auth.uid())=user_id) with check ((select auth.uid())=user_id);
 end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='mk_orders' and policyname='mk_order_owner') then
 create policy mk_order_owner on public.mk_orders for select to authenticated using ((select auth.uid())=user_id);
 end if;
end $$;
revoke all on public.mk_profiles,public.mk_catalog_items,public.mk_promotions,public.mk_orders,public.mk_order_lines from anon,authenticated;
grant select,insert,update on public.mk_profiles to authenticated;
-- Order tokens are never readable through the table API.
grant select(id,user_id,created_at,payment,step,final_state,pickup_ready_at,payload,is_demo) on public.mk_orders to authenticated;

create or replace function public.mk_phone(v text) returns text language sql immutable set search_path='' as $$
 select case when regexp_replace(coalesce(v,''),'[^0-9]','','g') ~ '^0[0-9]{9}$' then '+38'||regexp_replace(v,'[^0-9]','','g')
 else '+'||regexp_replace(coalesce(v,''),'[^0-9]','','g') end
$$;
create or replace function public.mk_full_name(v text) returns boolean language sql immutable set search_path='' as $$
 select length(coalesce(v,'')) between 3 and 120 and btrim(v) ~ '^[[:alpha:]’''ʼ-]+([[:space:]]+[[:alpha:]’''ʼ-]+)+$'
$$;
create or replace function public.mk_expire_pickups() returns void language plpgsql security definer set search_path='' as $$
begin
 update public.mk_orders set final_state='Не забрано',
 payload=payload||jsonb_build_object('finalState','Не забрано','status','⌛ Бронювання завершено','closedAt',now(),
 'history',coalesce(payload->'history','[]'::jsonb)||jsonb_build_array(jsonb_build_object('title','Не забрано — бронювання завершено','time',to_char(now() at time zone 'Europe/Kyiv','DD.MM.YY HH24:MI'))))
 where payment='pickup' and step=3 and final_state is null and pickup_ready_at<=now()-interval '24 hours';
end $$;
create or replace function public.mk_catalog() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform pg_advisory_xact_lock(734091);
 perform public.mk_expire_pickups();
 select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('available',greatest(0,c.stock-coalesce(r.reserved,0)))),'[]'::jsonb) into result
 from public.mk_catalog_items c left join (
 select l.product_id,l.variant_key,sum(l.qty)::integer reserved from public.mk_order_lines l join public.mk_orders o on o.id=l.order_id where o.final_state is null group by l.product_id,l.variant_key
 ) r on r.product_id=c.product_id and r.variant_key=c.variant_key;
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
 if not found or not c.is_demo then raise exception 'Товар не доступний у демокаталозі'; end if;
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
create or replace function public.mk_list_orders() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null then raise exception 'Увійди в акаунт'; end if;
 perform pg_advisory_xact_lock(734091);perform public.mk_expire_pickups();
 select coalesce(jsonb_agg(payload order by created_at desc),'[]'::jsonb) into result from public.mk_orders where user_id=auth.uid();
 return result;
end $$;
create or replace function public.mk_guest_order(p_request_id uuid,p_access_token uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform pg_advisory_xact_lock(734091);perform public.mk_expire_pickups();
 select payload into result from public.mk_orders where user_id is null and request_id=p_request_id and access_token=p_access_token;
 if result is null then raise exception 'Замовлення не знайдене';end if;return result;
end $$;
create or replace function public.mk_cancel_order(p_id uuid,p_access_token uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.mk_orders; result jsonb;
begin
 perform pg_advisory_xact_lock(734091);perform public.mk_expire_pickups();
 select * into o from public.mk_orders where id=p_id for update;
 if not found or not coalesce(((o.user_id is not null and o.user_id=auth.uid()) or (o.user_id is null and o.access_token=p_access_token)),false) then raise exception 'Замовлення не знайдене';end if;
 if o.final_state is not null then return o.payload;end if;
 if (o.payment='pickup' and o.step>=4) or (o.payment='cod' and o.step>=3) then raise exception 'На цьому етапі скасування — через підтримку';end if;
 result=o.payload||jsonb_build_object('finalState','Скасовано','status','❌ Скасовано клієнтом','history',coalesce(o.payload->'history','[]'::jsonb)||jsonb_build_array(jsonb_build_object('title','Скасовано клієнтом','time',to_char(now() at time zone 'Europe/Kyiv','DD.MM.YY HH24:MI'))));
 update public.mk_orders set final_state='Скасовано',payload=result where id=o.id;return result;
end $$;
revoke all on function public.mk_phone(text),public.mk_full_name(text),public.mk_expire_pickups(),public.mk_catalog(),public.mk_create_order(uuid,uuid,jsonb),public.mk_list_orders(),public.mk_guest_order(uuid,uuid),public.mk_cancel_order(uuid,uuid) from public,anon,authenticated;
grant execute on function public.mk_catalog(),public.mk_create_order(uuid,uuid,jsonb),public.mk_guest_order(uuid,uuid),public.mk_cancel_order(uuid,uuid) to anon,authenticated;
grant execute on function public.mk_list_orders() to authenticated;
-- These values are copied from the agreed demonstration catalogue.
insert into public.mk_catalog_items(product_id,variant_key,name,variant,photo,warranty,price,stock,is_demo) values
('case-magsafe','iphone15pro-black','MagSafe чохол','iPhone 15 Pro · Чорний','','Не вказано',499,5,true),
('case-magsafe','iphone15pro-clear','MagSafe чохол','iPhone 15 Pro · Прозорий','','Не вказано',499,2,true),
('case-magsafe','iphone14-black','MagSafe чохол','iPhone 14 · Чорний','','Не вказано',499,1,true),
('case-gleam-magnetic','','GLEAM Case with Magnetic Ring','','https://content1.rozetka.com.ua/goods/images/big/578240497.jpg','Не вказано',549,99,true),
('case-carbon','','Carbon Fiber чохол','','','Не вказано',449,99,true),
('case-glitter','','Блискучий чохол зі стразами','','','Не вказано',499,99,true),
('case-nasa','','Чохол NASA / Space','','','Не вказано',449,99,true),
('case-wave','','Чохол Wave','','','Не вказано',449,99,true),
('case-bear','','Чохол Bear','','','Не вказано',449,99,true),
('case-pearlescent','','Перламутровий чохол','','','Не вказано',499,99,true),
('case-plain','','Однотонний чохол','','','Не вказано',399,99,true),
('case-mirror','','Дизайнерський дзеркальний чохол','','','Не вказано',499,99,true),
('case-white-glitter','','Білий блискучий чохол','','','Не вказано',499,99,true),
('hoco-h86-dragon','','Hoco H86 Dragon','','','Не вказано',699,99,true),
('remax-car-holder','','Автотримач Remax','','','Не вказано',699,99,true),
('camera-am300','','Дитяча фотокамера AM300 «Звірятка»','','','Не вказано',1499,99,true),
('camera-a23','','Дитяча фотокамера A23','','','Не вказано',1499,99,true),
('camera-ai9','','Дитячий фотоапарат AI9','','','Не вказано',1599,99,true),
('camera-m05','','Дитяча фотокамера Animals M05','','','Не вказано',1499,99,true),
('camera-a26','','Фотокамера A26','','https://www.7md.ae/web/image/product.image/60081/image_1024/Lily%20Toy%20Kids%20Instant%20Print%20Camera%2048MP%201080P%20800mAh?unique=ed54571','Не вказано',1599,99,true),
('camera-q5','','Дитяча фотокамера Q5','','https://a.allegroimg.com/original/1127fe/81ff89394df1b66b67e28b9d6e56/Aparat-dla-dzieci-z-drukarka-termiczna-natychmiastowa-dla-dziecka-Q5-uszy','Не вказано',1699,99,true),
('printer-a8c-mini','','Термопринтер A8C Mini','','https://down-id.img.susercontent.com/file/sg-11134201-23010-9x8k1zwcfgmv09','Не вказано',999,99,true),
('printer-d7-rabbit','','Портативний термопринтер Mini D7 Rabbit','','https://i.ebayimg.com/images/g/CoIAAOSwOx9mBqXd/s-l1600.jpg','Не вказано',1099,99,true),
('walker-wts67','','Walker WTS-67 ANC+ENC','','https://stylecom.ua/image/cache/catalog/photos/29020/2-jpg-17-1000x1000.jpg','Не вказано',1399,99,true),
('walker-wts11','','Walker WTS-11','','https://content1.rozetka.com.ua/goods/images/original/531998466.jpg','Не вказано',899,99,true),
('remax-tws01','','Remax TWS-01 Sleepy','','https://image.made-in-china.com/2f0j00qyJWEULaqRYI/Remax-Tws-01-True-Wireless-Sleep-Earbuds-with-Bluetooth-Compatible-Stereo-Headphones-Noise-Cancelling-Tws.jpg','Не вказано',999,99,true),
('onikuma-t18','','Onikuma T18 Camera','','https://media-cdn.bnn.in.th/386770/onikuma-gaming-headset-t18-tws-earphone-white-1.jpg','Не вказано',1199,99,true),
('hoco-ea8','','HOCO EA8','','','Не вказано',1099,99,true),
('hoco-ew87','','HOCO EW87','','','Не вказано',1199,99,true),
('hoco-ea4','','HOCO EA4 OWS','','https://static-01.daraz.com.bd/p/caaf4e2f044e8a865b6f98902d05439c.jpg','Не вказано',1199,99,true),
('hoco-ew23','','HOCO EW23','','https://hoco.vn/data/Product/tai-nghe-airpod-ew23-BmWerI72LH72D0R5QwmA.jpg','Не вказано',999,99,true),
('remax-openbuds-p9','','Remax OpenBuds P9','','','Не вказано',1299,99,true),
('proove-dreamer','','Proove Dreamer','','https://prooveglobal.com/image/cache/products/84/61/846128f2-c9e4-11f0-810d-a8a1593ebe6e-600x600.webp','Не вказано',1399,99,true),
('proove-mello','','Proove Mello','','https://prooveglobal.com/image/cache/products/fe/cb/fecb947d-ed4a-11f0-8111-a8a1593ebe6e-600x600.webp','Не вказано',1299,99,true),
('rolling-face-tws','','Rolling Face TWS','','','Не вказано',999,99,true),
('remax-ap10','','Remax AP10','','https://mouse.ge/files/resized/products/remax-ap103.600x800.jpg','Не вказано',849,99,true),
('hoco-gm111','','HOCO GM111','','https://www.techcrazy.co.nz/cdn/shop/files/Hoco-Multi-Function-Universal-Stylus-Pen-_GM111_-MBP01267-4.jpg?v=1749087397','Не вказано',349,99,true),
('remax-ap08','','Remax AP08','','https://cdn.hstatic.net/products/200000685523/z7715848472551_32bdca33361271d9fcfb48d18d997c55_9c70e807513f4822920cf6b82f09f78e_grande.jpg','Не вказано',749,99,true),
('baseus-golden','','Baseus Golden Cudgel Stylus Pen','','','Не вказано',399,99,true),
('baseus-smooth3','','Baseus Smooth Writing 3','','','Не вказано',449,99,true),
('proove-sp03','','Proove SP-03','','','Не вказано',399,99,true),
('proove-sp01','','Proove SP-01','','https://files.foxtrot.com.ua/PhotoNew/img_0_1403_237_0_1_y8Knib.jpg','Не вказано',399,99,true),
('borofone-bg100','','Borofone BG100','','https://cs.vchehle.ua/uploads/CGm34mHevILt7Qha47qNiAI7wppf5ai4.jpg','Не вказано',899,99,true),
('remax-ap07','','Remax AP07','','','Не вказано',799,99,true),
('acefast-v1','','Acefast V1','','https://www.xmart.jo/cdn/shop/files/acefast-v1-universal-capacitive-pen-stylus.webp?v=1768207466&width=645','Не вказано',749,99,true),
('xo-m8-pro','','XO M8 Pro','','https://external.webstorage.gr/mmimages/image/29/22/79/88/MRK3060312-XO-6920680837991-01-560x560.jpg','Не вказано',1499,99,true),
('xo-m8-ultra','','XO M8 Ultra','','','Не вказано',1599,99,true),
('xo-watch4','','XO Watch 4','','','Не вказано',1699,99,true),
('gs-fenix7','','GS Fenix 7','','','Не вказано',1899,99,true),
('hoco-y25','','HOCO Y25','','https://hoco-optom.ru/wa-data/public/shop/products/37/04/10437/images/42337/42337.750x0.png','Не вказано',999,99,true),
('hoco-y34','','HOCO Y34','','https://hoco.vn/data/Product/dong-ho-the-thao-thong-minh-hoco-y34-phien-ban-goi-dien-d13sHqZ9G5irYWx9JdG3.jpg','Не вказано',1099,99,true),
('projector-v8','','V8 Projector','','','Не вказано',3999,99,true),
('hy300','','HY300 Projector','','https://omegisza.pl/43765-large_default/przenosny-rzutnik-projektor-android-110-tv-wifi-bluetooth-hdmi-glosnik.jpg','Не вказано',2999,99,true),
('amx500','','AMX500 Projector','','','Не вказано',3199,99,true),
('hoco-dt1','','HOCO DT1','','https://i00.eu/img/716/1600x1600/525ss9tg/102492.jpg','Не вказано',2799,99,true),
('alien-star-projector','','Лазерний проектор зоряного неба «Інопланетянин»','','','Не вказано',999,99,true),
('aimb-g1','','Smart AI Glasses AIMB-G1','','https://s.alicdn.com/%40sc04/kf/Hc3c9c696022245e491d44191ad4f4bf2q.jpg','Не вказано',2499,99,true),
('selfie-screen-a1','','Magnetic Phone Vlog Selfie Screen A1','','','Не вказано',999,99,true),
('mj261','','MJ-261 RGB Fill Light','','','Не вказано',1499,99,true),
('mj321','','MJ-321 Ring Light','','','Не вказано',1699,99,true),
('rechargeable-light-35','','Акумуляторна лампа 35 см','','','Не вказано',699,99,true),
('rechargeable-light-50','','Акумуляторна лампа 50 см','','','Не вказано',799,99,true),
('baseus-fm11','10000-black','Baseus EnerFill FM11 10000mAh','10000 mAh · Чорний','https://eu.baseus.com/cdn/shop/files/Baseus_EnerFill_FM11_Magnetic_Power_Bank_10000mAh_22.5W_4_1200x.jpg?v=1759227033','Не вказано',1799,4,true),
('baseus-fm11','10000-white','Baseus EnerFill FM11 10000mAh','10000 mAh · Білий','https://eu.baseus.com/cdn/shop/files/Baseus_EnerFill_FM11_Magnetic_Power_Bank_10000mAh_22.5W_4_1200x.jpg?v=1759227033','Не вказано',1799,1,true),
('xo-magsafe-5000','','XO MagSafe Power Bank 5000mAh','','','Не вказано',1199,99,true),
('hoco-j160b','','Hoco J160B Original 20000mAh','','https://http2.mlstatic.com/D_NQ_NP_932873-MLA110632939933_042026-O.webp','Не вказано',1899,99,true),
('hoco-j117-5000','','Hoco J117/J117A Esteem 5000mAh','','','Не вказано',1099,99,true),
('hoco-j117-10000','','Hoco J117/J117A Esteem 10000mAh','','','Не вказано',1499,99,true),
('acefast-m17','','AceFast M17 10000mAh','','https://bobbystore.kg/wa-data/public/shop/products/68/54/85468/images/104240/104240.970.jpg','Не вказано',1699,99,true),
('walker-wb710','','Walker WB-710 10000mAh','','','Не вказано',1599,99,true),
('proove-xcore','','Proove X-Core 22.5W 10000mAh','','https://cdn.27.ua/sc--media--prod/default/bd/7f/82/bd7f82e4-323e-4a48-8c91-c2fc17ee35b6.jpeg','Не вказано',1299,99,true),
('proove-hoodman','','Proove Hoodman Magnetic 10000mAh','','https://ncase.ua/images/cHJvZHVjdHMvYmIvNzkvYmI3OTcxOTMtMDU1MC00M2RhLWI4MjAtMmZjNmI3NWU3MWJmLmpwZzoxMDAwOjEwMDA%3D.jpg','Не вказано',1599,99,true),
('proove-carbon-slim','','Proove Carbon Slim 22.5W 10000mAh','','https://images.prom.ua/7071314984_w1280_h640_7071314984.jpg','Не вказано',1699,99,true),
('remax-rpp565','','Remax RPP-565 60000mAh','','https://rokbucket.rokomari.io/ProductNew20190903/260X372/Remax_RPP_565_60000mAh_225W_Fast_Chargin-Remax-d50e9-457509.png','Не вказано',2799,99,true),
('walker-typec-cable','','Walker Type-C ↔ Type-C кабель','','https://content1.rozetka.com.ua/goods/images/original/575555553.jpg','Не вказано',299,99,true),
('hoco-k24-gimbal','','HOCO K24 3-Axis Smart Gimbal','','https://phukiengiaxuong.com.vn/cdn/images/202509/source_img/hoco-k24-5.jpg','Не вказано',1999,99,true),
('baseus-gravity-car-mount','','Baseus Car Mount Tank Gravity','','https://static.insales-cdn.com/files/1/3483/22252955/original/c2d87deaad0f27a11a17ae020c8e5acf.png','Не вказано',699,99,true),
('walker-wh43-33w','','Walker WH-43 GaN 33W','','https://content1.rozetka.com.ua/goods/images/big/541751425.jpg','Не вказано',699,99,true),
('usb-c-25w-adapter','','USB-C 25W Power Adapter','','','Не вказано',599,99,true),
('proove-rapid-20w','','Proove RAPID 20W Charging Set','','https://aks.md/files/products/szu_proove_rapid_20w_type-c_cab_belyj_1.800x600w.png','Не вказано',699,99,true),
('acefast-a102','','Acefast A102','','','Не вказано',699,99,true),
('proove-nova-10w','','Proove NOVA Bluetooth Speaker 10W','','https://prooveglobal.com/image/cache/products/ed/62/ed627375-948d-11f0-8109-a8a1593ebe6e-600x600.webp','Не вказано',1299,99,true),
('speaker-qd05-retro','','QD05 Retro Style','','','Не вказано',1199,99,true),
('speaker-x868-bear','','X-868 Bear','','','Не вказано',1099,99,true),
('speaker-borofone-br101','','Borofone BR101 Rubik Cube','','https://cdn.smartdiszkont.hu/images/products/199/199368/borofone-hordozhato-bluetooth-hangszoro-br101-rubik-kek-199368-1024.webp','Не вказано',1199,99,true),
('speaker-walker-wtrs81','','Walker WTRS-81','','','Не вказано',1299,99,true),
('speaker-proove-facefix','','Proove Facefix','','','Не вказано',1399,99,true),
('speaker-walker-wsp750','','Walker WSP-750 60W','','','Не вказано',2499,99,true),
('speaker-80w-unidentified','','Портативна колонка 80W','','','Не вказано',2999,99,true),
('fan-mini-k9','','Mini K9 Astronaut','','https://cf.shopee.vn/file/89db9c47da22523aec071ef8d5d04b8d','Не вказано',699,99,true),
('fan-fs21','','FS-21 Telescopic Folding','','','Не вказано',799,99,true),
('fan-138-clip','','138 Clip 4in1','','','Не вказано',699,99,true),
('fan-y18','','Y-18','','','Не вказано',599,99,true),
('fan-remax-rssf01','','Remax RS-SF01 Transparent','','https://lcd-phone.com/103114-large_default/ventilateur-portable-remax-rs-sf01-transparent.jpg','Не вказано',799,99,true),
('fan-hoco-hx60','','HOCO HX60 Nimble','','https://phukienhoco.vn/data/Product/quat-cam-tay-di-dong-hx60-nimble-QxMmQadS4NYbd6ZyjuGe.jpg','Не вказано',699,99,true),
('fan-hoco-hx62','','HOCO HX62 Endless','','https://static-01.daraz.com.bd/p/5a14e4c33fa3d4ca31d3f9c261b4e07b.jpg','Не вказано',749,99,true),
('fan-hoco-hx61','','HOCO HX61 Exquisite','','https://www.e-fuchsia.com/uploads/urunler/hoco-hx61-exquisite-el-tipi-ve-masaustu-katlanabilir-sogutucu-fan-276461.webp','Не вказано',749,99,true),
('fan-baseus-gotrip-dt1','','Baseus GoTrip DT1','','https://down-my.img.susercontent.com/file/cn-11134207-7ras8-m7w2n0iw3nqq97','Не вказано',899,99,true),
('fan-proove-fresher','','Proove Fresher','','','Не вказано',799,99,true),
('cable-walker-power-silicone-100w','1m-black','Walker Power Silicone Type-C ↔ Type-C 100W','1 м · Чорний','https://content1.rozetka.com.ua/goods/images/original/575555553.jpg','Не вказано',399,6,true),
('cable-walker-power-silicone-100w','2m-black','Walker Power Silicone Type-C ↔ Type-C 100W','2 м · Чорний','https://content1.rozetka.com.ua/goods/images/original/575555553.jpg','Не вказано',399,2,true),
('cable-walker-power-silicone-100w','2m-white','Walker Power Silicone Type-C ↔ Type-C 100W','2 м · Білий','https://content1.rozetka.com.ua/goods/images/original/575555553.jpg','Не вказано',399,0,true),
('cable-walker-fast-100w','','Walker Fast Charging Type-C ↔ Type-C 100W','','https://content1.rozetka.com.ua/goods/images/original/598537326.jpg','Не вказано',399,99,true),
('cable-walker-qc20-silicone','','Walker Quick Charge 20W Silicone','','','Не вказано',349,99,true),
('cable-walker-jelly','','Walker Jelly Silicone Cable','','','Не вказано',299,99,true),
('cable-baseus-lightning','','Baseus Lightning Cable','','','Не вказано',349,99,true),
('cable-baseus-typec','','Baseus Type-C Cable','','','Не вказано',349,99,true),
('cable-baseus-high-current','','Baseus High Current Cable','','','Не вказано',399,99,true),
('cable-baseus-rapid-charge','','Baseus Rapid Charge Cable','','https://www.buyon.pk/image/cache/data/members/mjitraders/baseushalodatacableusbformicro2a2c3meterblackcamgh-e01-1620571441-386x386.jpg','Не вказано',399,99,true),
('cable-proove','','Proove Cable','','https://fopi.ua/image/catalog/uploads/b7/8f/b78fa046552574807ddc3f47fe831c1b.jpg','Не вказано',349,99,true)
on conflict(product_id,variant_key) do nothing;
insert into public.mk_promotions(product_id,sale_price,published,start_at,end_at) values
('proove-nova-10w',999,true,'2026-09-29T09:00:00+03:00','2026-10-06T21:00:00+03:00'),
('proove-dreamer',1099,true,'2026-09-30T09:00:00+03:00','2026-10-05T21:00:00+03:00'),
('baseus-fm11',1299,false,'2026-09-30T09:00:00+03:00','2026-10-07T21:00:00+03:00')
on conflict(product_id) do nothing;
commit;
