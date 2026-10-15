begin;
create table public.mk_categories(id text primary key check(id ~ '^[a-z][a-z0-9_-]{0,119}$'),name text not null check(length(btrim(name)) between 1 and 100));
create unique index mk_categories_name_unique on public.mk_categories(lower(btrim(name)));
alter table public.mk_categories enable row level security;
revoke all on public.mk_categories from public,anon,authenticated;
insert into public.mk_categories(id,name) values ('cases','Чохли на телефон'),
('speakers','Портативні колонки'),
('headphones','Навушники'),
('chargers','Зарядні пристрої'),
('holders','Автотримачі'),
('led','Освітлення'),
('projectors','Проектори'),
('styluses','Стилуси'),
('watches','Смарт-годинники'),
('powerbanks','PowerBank'),
('cables','Кабелі'),
('gadgets','Гаджети'),
('instantcameras','Фотоапарати миттєвого друку'),
('miniprinters','Мініпринтери'),
('fans','Вентилятори'),
('printing3d','3D-друк');
create function public.mk_admin_category_create(p_name text) returns jsonb language plpgsql security definer set search_path='' as $$
declare saved public.mk_categories;
begin
 perform pg_advisory_xact_lock(734091);
 perform 1 from public.mk_admin_members where user_id=auth.uid() and role in ('owner','administrator') for share;
 if not found then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_name is null or length(btrim(p_name)) not between 1 and 100 then raise exception 'Invalid category name' using errcode='22023'; end if;
 insert into public.mk_categories(id,name) values('cat-'||gen_random_uuid()::text,btrim(p_name)) returning * into saved;
 return to_jsonb(saved);
end $$;
revoke all on function public.mk_admin_category_create(text) from public,anon,authenticated;
grant execute on function public.mk_admin_category_create(text) to authenticated;
create or replace function public.mk_admin_product_save(p_item jsonb,p_revision bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare saved jsonb;
begin
 if public.mk_admin_role() is null or public.mk_admin_role() not in ('owner','administrator') then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_item is null or jsonb_typeof(p_item)<>'object' or not p_item ?& array['category','description']
 or jsonb_typeof(p_item->'category')<>'string' or jsonb_typeof(p_item->'description')<>'string'
 or length(p_item->>'description')>4000 or not exists(select 1 from public.mk_categories where id=p_item->>'category') then raise exception 'Invalid category or description' using errcode='22023'; end if;
 saved=public.mk_admin_catalog_save(p_item-'category'-'description',p_revision);
 update public.mk_catalog_items set category=p_item->>'category',description=p_item->>'description'
 where product_id=saved->>'product_id' and variant_key=saved->>'variant_key';
 return saved||jsonb_build_object('category',p_item->>'category','description',p_item->>'description');
end $$;
revoke all on function public.mk_admin_product_save(jsonb,bigint) from public,anon,authenticated;
grant execute on function public.mk_admin_product_save(jsonb,bigint) to authenticated;

create or replace function public.mk_storefront() returns jsonb
language plpgsql security definer set search_path='' as $$
declare items jsonb; offers jsonb;
begin
 items=public.mk_catalog();
 select coalesce(jsonb_agg(jsonb_build_object('id',p.product_id,'salePrice',p.sale_price,'published',true,'startAt',p.start_at,'endAt',p.end_at)),'[]'::jsonb)
 into offers from public.mk_promotions p where p.published and exists(select 1 from public.mk_catalog_items c where c.product_id=p.product_id and c.published)
 and (p.start_at is null or p.start_at<=now()) and (p.end_at is null or p.end_at>now());
 return jsonb_build_object('items',items,'promotions',offers,'categories',(select coalesce(jsonb_agg(to_jsonb(c) order by c.name),'[]'::jsonb) from public.mk_categories c));
end $$;
revoke all on function public.mk_storefront() from public,anon,authenticated;
grant execute on function public.mk_storefront() to anon,authenticated;

notify pgrst,'reload schema';
commit;
