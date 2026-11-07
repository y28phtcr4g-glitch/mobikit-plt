-- Product photo galleries: up to 10 public HTTPS images per catalog variant.
-- Keeps the legacy photo column as the primary-image compatibility field.
begin;

alter table public.mk_catalog_items
  add column photos jsonb not null default '[]'::jsonb;

update public.mk_catalog_items
set photos = case
  when photo is not null and photo <> '' then jsonb_build_array(photo)
  else '[]'::jsonb
end;

alter table public.mk_catalog_items
  add constraint mk_catalog_photos_array_check
  check (jsonb_typeof(photos) = 'array' and jsonb_array_length(photos) <= 10);

create or replace function public.mk_admin_product_save(p_item jsonb,p_revision bigint)
returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  saved jsonb;
  saved_row public.mk_catalog_items;
  item_for_save jsonb;
  photo_list jsonb;
  photo_count integer;
begin
  if public.mk_admin_role() is null
     or public.mk_admin_role() not in ('owner','administrator') then
    raise exception 'Not authorized' using errcode='42501';
  end if;

  if p_item is null or jsonb_typeof(p_item)<>'object'
     or not p_item ?& array['category','description']
     or jsonb_typeof(p_item->'category')<>'string'
     or jsonb_typeof(p_item->'description')<>'string'
     or length(p_item->>'description')>4000
     or not exists(select 1 from public.mk_categories where id=p_item->>'category') then
    raise exception 'Invalid category or description' using errcode='22023';
  end if;

  if p_item ? 'photos' then
    photo_list := p_item->'photos';
    if jsonb_typeof(photo_list)<>'array' then
      raise exception 'Photos must be an array' using errcode='22023';
    end if;
  else
    photo_list := case
      when coalesce(p_item->>'photo','')='' then '[]'::jsonb
      else jsonb_build_array(p_item->>'photo')
    end;
  end if;

  photo_count := jsonb_array_length(photo_list);
  if photo_count > 10
     or exists (
       select 1
       from jsonb_array_elements(photo_list) as x(value)
       where jsonb_typeof(x.value)<>'string'
          or length(x.value #>> '{}') > 2000
          or (x.value #>> '{}') !~ '^https://[^[:space:]"<>\\@]+$'
     ) then
    raise exception 'Invalid photos: use up to 10 HTTPS URLs' using errcode='22023';
  end if;

  item_for_save := p_item - 'photos';
  item_for_save := jsonb_set(item_for_save, '{photo}',
    to_jsonb(case when photo_count>0 then photo_list->>0 else '' end), true);

  saved := public.mk_admin_catalog_save(item_for_save-'category'-'description',p_revision);

  update public.mk_catalog_items
     set category=p_item->>'category',
         description=p_item->>'description',
         photos=photo_list
   where product_id=saved->>'product_id'
     and variant_key=saved->>'variant_key'
   returning * into saved_row;

  return to_jsonb(saved_row);
end $$;

revoke all on function public.mk_admin_product_save(jsonb,bigint) from public,anon,authenticated;
grant execute on function public.mk_admin_product_save(jsonb,bigint) to authenticated;

notify pgrst,'reload schema';
commit;
