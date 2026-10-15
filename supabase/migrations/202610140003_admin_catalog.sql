-- RPC-only catalog increment: no seeded inventory or membership changes.
begin;
alter table public.mk_catalog_items add column revision bigint not null default 0;
revoke all on public.mk_catalog_items from public,anon,authenticated;

create function public.mk_admin_catalog_list() returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform pg_advisory_xact_lock(734091);
 perform 1 from public.mk_admin_members where user_id=auth.uid() and role in ('owner','administrator') for share;
 if not found then raise exception 'Not authorized' using errcode='42501'; end if;
 perform public.mk_expire_pickups();
 select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object(
 'reserved',coalesce(r.qty,0),'available',greatest(0,c.stock-coalesce(r.qty,0)),
 'orderable',case when c.published and c.is_demo then greatest(0,c.stock-coalesce(r.qty,0)-1) else 0 end
 ) order by c.product_id,c.variant_key),'[]'::jsonb) into result
 from public.mk_catalog_items c left join (
 select l.product_id,l.variant_key,sum(l.qty) qty from public.mk_order_lines l join public.mk_orders o on o.id=l.order_id
 where o.final_state is null group by l.product_id,l.variant_key
 ) r using(product_id,variant_key);
 return result;
end $$;

-- Full variant replacement. NULL revision creates a draft; identifiers/is_demo are immutable.
create function public.mk_admin_catalog_save(p_item jsonb,p_revision bigint) returns jsonb
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
 if not c.is_demo then raise exception 'Live inventory management is not enabled' using errcode='22023'; end if;
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
 amount,physical,true,(p_item->>'published')::boolean,0)
 on conflict(product_id,variant_key) do update set
 name=excluded.name,variant=excluded.variant,photo=excluded.photo,warranty=excluded.warranty,
 price=excluded.price,stock=excluded.stock,published=excluded.published,revision=public.mk_catalog_items.revision+1
 returning * into saved;
 return to_jsonb(saved);
end $$;
revoke all on function public.mk_admin_catalog_list(),public.mk_admin_catalog_save(jsonb,bigint) from public,anon,authenticated;
grant execute on function public.mk_admin_catalog_list(),public.mk_admin_catalog_save(jsonb,bigint) to authenticated;
commit;
