begin;
alter table public.mk_catalog_items add column category text not null default 'gadgets';
alter table public.mk_catalog_items add column description text not null default '';
alter table public.mk_promotions add column revision bigint not null default 0;
revoke all on public.mk_promotions from public,anon,authenticated;
create function public.mk_admin_product_save(p_item jsonb,p_revision bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare saved jsonb;
begin
 if public.mk_admin_role() is null or public.mk_admin_role() not in ('owner','administrator') then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_item is null or jsonb_typeof(p_item)<>'object' or not p_item ?& array['category','description']
 or jsonb_typeof(p_item->'category')<>'string' or jsonb_typeof(p_item->'description')<>'string'
 or length(p_item->>'description')>4000 or p_item->>'category' not in
 ('cases','speakers','headphones','chargers','holders','led','projectors','styluses','watches','powerbanks','cables','gadgets','instantcameras','miniprinters','fans','printing3d') then raise exception 'Invalid category or description' using errcode='22023'; end if;
 saved=public.mk_admin_catalog_save(p_item-'category'-'description',p_revision);
 update public.mk_catalog_items set category=p_item->>'category',description=p_item->>'description'
 where product_id=saved->>'product_id' and variant_key=saved->>'variant_key';
 return saved||jsonb_build_object('category',p_item->>'category','description',p_item->>'description');
end $$;
revoke all on function public.mk_admin_product_save(jsonb,bigint) from public,anon,authenticated;
grant execute on function public.mk_admin_product_save(jsonb,bigint) to authenticated;
create function public.mk_admin_promotions() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.mk_admin_members where user_id=auth.uid() and role in ('owner','administrator') for share;
 if not found then raise exception 'Not authorized' using errcode='42501'; end if;
 return (select coalesce(jsonb_agg(to_jsonb(p) order by product_id),'[]'::jsonb) from public.mk_promotions p);
end $$;
create function public.mk_admin_promotion_save(p_item jsonb,p_revision bigint) returns jsonb
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
 or not exists(select 1 from public.mk_catalog_items where product_id=p_item->>'product_id' and is_demo) then raise exception 'Invalid promotion' using errcode='22023'; end if;
 select * into old from public.mk_promotions where product_id=p_item->>'product_id' for update;
 if (found and (p_revision is null or p_revision<>old.revision)) or (not found and p_revision is not null) then raise exception 'Promotion changed; reload' using errcode='40001'; end if;
 insert into public.mk_promotions(product_id,sale_price,published,start_at,end_at,revision)
 values(p_item->>'product_id',amount,(p_item->>'published')::boolean,starts,ends,0)
 on conflict(product_id) do update set sale_price=excluded.sale_price,published=excluded.published,start_at=excluded.start_at,end_at=excluded.end_at,revision=public.mk_promotions.revision+1 returning * into saved;
 return to_jsonb(saved);
end $$;
revoke all on function public.mk_admin_promotions(),public.mk_admin_promotion_save(jsonb,bigint) from public,anon,authenticated;
grant execute on function public.mk_admin_promotions(),public.mk_admin_promotion_save(jsonb,bigint) to authenticated;
create function public.mk_storefront() returns jsonb
language plpgsql security definer set search_path='' as $$
declare items jsonb; offers jsonb;
begin
 items=public.mk_catalog();
 select coalesce(jsonb_agg(jsonb_build_object('id',p.product_id,'salePrice',p.sale_price,'published',true,'startAt',p.start_at,'endAt',p.end_at)),'[]'::jsonb)
 into offers from public.mk_promotions p where p.published and exists(select 1 from public.mk_catalog_items c where c.product_id=p.product_id and c.published)
 and (p.start_at is null or p.start_at<=now()) and (p.end_at is null or p.end_at>now());
 return jsonb_build_object('items',items,'promotions',offers);
end $$;
revoke all on function public.mk_storefront() from public,anon,authenticated;
grant execute on function public.mk_storefront() to anon,authenticated;
update public.mk_catalog_items c set category=v.category,description=v.description from (values
('case-magsafe','cases','Чохол із магнітним кільцем MagSafe. Точну сумісність із моделями телефону уточнюй у магазині.'),
('case-gleam-magnetic','cases','Чохол GLEAM із Magnetic Ring. Сумісність залежить від моделі телефону.'),
('hoco-h86-dragon','holders','Автомобільний тримач Hoco H86 Dragon із наданих матеріалів. Додаткові характеристики не вигадуємо.'),
('baseus-gravity-car-mount','holders','Гравітаційний автомобільний тримач Baseus. На упаковці зазначені обертання 360°, телескопічна конструкція 21 см та регулювання кута.'),
('camera-a26','instantcameras','Миттєвий друк, фронтальна камера, основна камера до 48 MP, microSD до 32 GB, вбудований акумулятор. Характеристики зі сторіс магазину.'),
('camera-q5','instantcameras','Фото та друк зі смартфона через Bluetooth + APP, термодрук на папері 57 мм, 2.4-дюймовий IPS-дисплей, рамки, стікери й малюнки, Type-C. Характеристики зі сторіс магазину.'),
('printer-d7-rabbit','miniprinters','Android та iPhone через Bluetooth, друк текстів, фото, нотаток, чек-листів і стікерів, без чорнила, акумулятор 1000 mAh, Type-C. Характеристики зі сторіс магазину.'),
('walker-wts67','headphones','ANC+ENC, Bluetooth 5.4, до 6 годин роботи та до 50 годин із кейсом, Type-C або Qi.'),
('proove-dreamer','headphones','ANC, transparency, game mode, до 6 годин, застосунок Proove, IPX4.'),
('proove-mello','headphones','ANC, game mode, transparency, до 5 годин + кейс 400 mAh, IPX4, керування через застосунок.'),
('remax-ap10','styluses','LED-дисплей заряду, до 8 годин роботи, заряджання Type-C близько 30 хв.'),
('borofone-bg100','styluses','Дисплей, захист від випадкових дотиків та підтримка нахилу.'),
('xo-m8-pro','watches','2.01” IPS, сповіщення, активність, до 3 днів активної роботи / до 15 днів очікування, IP67.'),
('xo-watch4','watches','1.43” AMOLED, дзвінки, пульс, сатурація, спорт, IP68, до 5 днів.'),
('hy300','projectors','Android 12, 1280×720, Wi‑Fi 2.4G/5G + Bluetooth, 16 GB, HDMI-IN, поворотний корпус 180°.'),
('hoco-dt1','projectors','1280×720, екран 20–200 дюймів, Wi‑Fi 2.4G/5G + Bluetooth 5.0, HDMI/USB/AV, ручне фокусування.'),
('aimb-g1','gadgets','Камера 8 МП, Full HD 1080P, 32 GB пам’яті, звук без навушників, голосове керування та змінні лінзи — за даними сторіс.'),
('hoco-k24-gimbal','gadgets','3-осьовий стабілізатор для смартфона. На упаковці зазначені intelligent tracking, anti-shake, APP та режим штатива.'),
('mj261','led','Кільцева RGB-лампа для фото, відео та контенту.'),
('rechargeable-light-35','led','Лампа довжиною 35 см; у сторіс заявлено до 8 годин роботи без підзарядки.'),
('baseus-fm11','powerbanks','10000 mAh, магнітна бездротова зарядка до 15W, до 22.5W через Type-C, компактний корпус.'),
('proove-hoodman','powerbanks','10000 mAh, Magnetic Ring, PD 20W через Type-C, LED-дисплей заряду.'),
('remax-rpp565','powerbanks','60000 mAh; на фото та публікації зазначено 20W + 22.5W.'),
('walker-wh43-33w','chargers','Мережевий GaN-адаптер Walker WH-43 потужністю 33W, порти USB та Type-C — за даними упаковки.'),
('proove-rapid-20w','chargers','Мережевий зарядний комплект Proove RAPID 20W: Type-C адаптер, Power Delivery та кабель Type-C → Lightning — за даними упаковки.'),
('proove-nova-10w','speakers','Портативна Bluetooth-колонка Proove NOVA, 10W — за маркуванням на упаковці.'),
('speaker-walker-wsp750','speakers','Портативна колонка Walker WSP-750, 60W — за даними наданих матеріалів.'),
('fan-hoco-hx60','fans','Портативний вентилятор HOCO HX60 Nimble із наданих матеріалів.'),
('fan-baseus-gotrip-dt1','fans','Портативний вентилятор Baseus GoTrip DT1 із наданих матеріалів.'),
('cable-walker-power-silicone-100w','cables','Кабель Walker Type-C ↔ Type-C 100W; назва Power Silicone читається на упаковці.'),
('cable-baseus-rapid-charge','cables','Кабель Baseus Rapid Charge із наданих матеріалів; точний артикул не підтверджено.')) as v(id,category,description) where c.product_id=v.id;
commit;
