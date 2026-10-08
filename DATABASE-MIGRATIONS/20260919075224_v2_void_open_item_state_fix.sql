-- 20260919075224  v2_void_open_item_state_fix
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace function public.void_transaction(p_transaction_id uuid,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_tx public.transactions%rowtype; v_j public.journals%rowtype; v_rev uuid; v_m public.stock_movements%rowtype; v_a public.allocations%rowtype; v_open public.open_items%rowtype; v_result jsonb; v_has_open_item boolean:=false;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key))<8 then raise exception 'idempotency key must contain at least 8 characters'; end if;
  select * into v_tx from public.transactions where id=p_transaction_id for update;
  if not found then raise exception 'transaction not found'; end if;
  if not private.has_permission(v_tx.organization_id,v_uid,'transaction.void') then raise exception 'void permission denied'; end if;
  if v_tx.status='void' then return jsonb_build_object('transaction_id',v_tx.id,'document_no',v_tx.document_no,'status','void','idempotent',true); end if;
  if v_tx.status<>'posted' then raise exception 'only posted transactions can be voided'; end if;
  perform private.assert_period_open(v_tx.organization_id,v_tx.transaction_date);
  select * into v_open from public.open_items where transaction_id=v_tx.id and organization_id=v_tx.organization_id;
  v_has_open_item:=found;
  if v_has_open_item and v_open.allocated_amount>0 then raise exception 'cannot void an invoice/bill with allocations; reverse allocations first'; end if;
  for v_a in select * from public.allocations where payment_transaction_id=v_tx.id and organization_id=v_tx.organization_id for update loop
    update public.open_items set allocated_amount=greatest(allocated_amount-v_a.amount,0),status=case when greatest(allocated_amount-v_a.amount,0)=0 then 'open' else 'partially_paid' end where id=v_a.open_item_id;
  end loop;
  delete from public.allocations where payment_transaction_id=v_tx.id and organization_id=v_tx.organization_id;
  if v_has_open_item then update public.open_items set status='void' where id=v_open.id; end if;
  for v_m in select * from public.stock_movements where transaction_id=v_tx.id and organization_id=v_tx.organization_id and reason<>'void reversal' order by created_at for update loop
    update public.stock_balances set quantity=quantity-v_m.quantity_in+v_m.quantity_out,updated_at=now() where organization_id=v_tx.organization_id and product_id=v_m.product_id and warehouse_id=v_m.warehouse_id;
    insert into public.stock_movements(organization_id,transaction_id,transaction_line_id,product_id,warehouse_id,quantity_in,quantity_out,unit_cost,reason,created_by)
      values(v_tx.organization_id,v_tx.id,v_m.transaction_line_id,v_m.product_id,v_m.warehouse_id,v_m.quantity_out,v_m.quantity_in,v_m.unit_cost,'void reversal',v_uid);
  end loop;
  select * into v_j from public.journals where transaction_id=v_tx.id and reversal_of is null;
  if found then
    insert into public.journals(organization_id,transaction_id,journal_date,status,reversal_of,created_by) values(v_tx.organization_id,v_tx.id,current_date,'posted',v_j.id,v_uid) returning id into v_rev;
    insert into public.journal_lines(organization_id,journal_id,account_id,party_id,description,debit,credit)
      select organization_id,v_rev,account_id,party_id,'Reversal of '||coalesce(v_tx.document_no,''),credit,debit from public.journal_lines where journal_id=v_j.id;
    update public.journals set status='reversed' where id=v_j.id;
  end if;
  perform set_config('app.allow_posted_mutation','on',true);
  update public.transactions set status='void',voided_at=now(),voided_by=v_uid where id=v_tx.id;
  perform set_config('app.allow_posted_mutation','off',true);
  v_result:=jsonb_build_object('transaction_id',v_tx.id,'document_no',v_tx.document_no,'status','void');
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values) values(v_tx.organization_id,v_uid,'transaction.voided','transaction',v_tx.id::text,v_result);
  return v_result;
end $$;
revoke all on function public.void_transaction(uuid,text) from public, anon;
grant execute on function public.void_transaction(uuid,text) to authenticated;;
