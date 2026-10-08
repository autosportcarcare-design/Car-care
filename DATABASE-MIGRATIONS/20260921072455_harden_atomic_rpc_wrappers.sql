-- 20260921072455  harden_atomic_rpc_wrappers
-- Applied to Supabase project pwzpljitxamthgqllgtu

grant execute on function private.save_transaction_draft_v2(uuid,jsonb,jsonb) to authenticated;
grant execute on function private.save_and_post_transaction(uuid,jsonb,jsonb,text) to authenticated;

create or replace function public.save_transaction_draft_v2(p_organization_id uuid,p_transaction jsonb,p_lines jsonb)
returns jsonb language sql security invoker set search_path='' as $$ select private.save_transaction_draft_v2($1,$2,$3); $$;
revoke all on function public.save_transaction_draft_v2(uuid,jsonb,jsonb) from public,anon;
grant execute on function public.save_transaction_draft_v2(uuid,jsonb,jsonb) to authenticated;

create or replace function public.save_and_post_transaction(p_organization_id uuid,p_transaction jsonb,p_lines jsonb,p_idempotency_key text)
returns jsonb language sql security invoker set search_path='' as $$ select private.save_and_post_transaction($1,$2,$3,$4); $$;
revoke all on function public.save_and_post_transaction(uuid,jsonb,jsonb,text) from public,anon;
grant execute on function public.save_and_post_transaction(uuid,jsonb,jsonb,text) to authenticated;

create or replace function public.get_transaction_verification(p_organization_id uuid,p_transaction_id uuid)
returns jsonb
language plpgsql security invoker set search_path=''
as $$
declare v_uid uuid:=auth.uid(); v_tx public.transactions%rowtype; v_debit numeric; v_credit numeric;
begin
  if v_uid is null or not private.has_permission(p_organization_id,v_uid,'transaction.view') then raise exception 'permission denied'; end if;
  select * into v_tx from public.transactions where id=p_transaction_id and organization_id=p_organization_id;
  if not found then raise exception 'transaction not found'; end if;
  select coalesce(sum(l.debit),0),coalesce(sum(l.credit),0) into v_debit,v_credit
  from public.journals j join public.journal_lines l on l.journal_id=j.id and l.organization_id=j.organization_id
  where j.transaction_id=p_transaction_id and j.organization_id=p_organization_id and j.reversal_of is null;
  return jsonb_build_object(
    'transaction_id',v_tx.id,'document_no',v_tx.document_no,'status',v_tx.status,'company_id',v_tx.company_id,'branch_id',v_tx.branch_id,
    'grand_total',v_tx.grand_total,'paid_total',v_tx.paid_total,'balance_total',v_tx.balance_total,
    'line_count',(select count(*) from public.transaction_lines where transaction_id=v_tx.id and organization_id=p_organization_id),
    'journal_count',(select count(*) from public.journals where transaction_id=v_tx.id and organization_id=p_organization_id),
    'journal_debit',v_debit,'journal_credit',v_credit,'journal_balanced',(round(v_debit,2)=round(v_credit,2)),
    'stock_movement_count',(select count(*) from public.stock_movements where transaction_id=v_tx.id and organization_id=p_organization_id),
    'ar_ap_count',(select count(*) from public.open_items where transaction_id=v_tx.id and organization_id=p_organization_id),
    'snapshot_count',(select count(*) from public.document_snapshots where transaction_id=v_tx.id and organization_id=p_organization_id)
  );
end $$;
revoke all on function public.get_transaction_verification(uuid,uuid) from public,anon;
grant execute on function public.get_transaction_verification(uuid,uuid) to authenticated;;
