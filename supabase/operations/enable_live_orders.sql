-- Run only after owner confirms published prices/stock and live UI is deployed.
begin;
select pg_advisory_xact_lock(734091);
update public.mk_catalog_items set is_demo=false,revision=revision+1 where is_demo;
update public.mk_store_settings set live_orders=true where singleton;
commit;
select live_orders,(select count(*) from public.mk_catalog_items) as variants,(select sum(stock) from public.mk_catalog_items) as physical_units from public.mk_store_settings;
