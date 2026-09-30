begin;
-- Keep the public receipt consistent with administrator updates.
create or replace function public.mk_sync_order_receipt() returns trigger
language plpgsql set search_path='' as $$
declare label text; stamp text=to_char(now() at time zone 'Europe/Kyiv','DD.MM.YY HH24:MI');
begin
 if new.payment='pickup' and new.step=3 and new.pickup_ready_at is null then new.pickup_ready_at=now();end if;
 new.payload=new.payload||jsonb_build_object('step',new.step,'finalState',new.final_state,'pickupReadyAt',new.pickup_ready_at);
 if new.step is distinct from old.step and new.final_state is null then
 label=(case when new.payment='pickup' then array['Створено','Підтверджено','Комплектується','Готове до самовивозу','Видано','Завершено'] else array['Створено','Підтверджено','Комплектується','Укомплектовано','Передано НП','Отримано'] end)[new.step+1];
 new.payload=new.payload||jsonb_build_object('status',label,'history',coalesce(new.payload->'history','[]'::jsonb)||jsonb_build_array(jsonb_build_object('title',label,'time',stamp)));
 end if;
 return new;
end $$;
revoke all on function public.mk_sync_order_receipt() from public,anon,authenticated;
drop trigger if exists mk_order_receipt on public.mk_orders;
create trigger mk_order_receipt before update on public.mk_orders for each row execute function public.mk_sync_order_receipt();
commit;
