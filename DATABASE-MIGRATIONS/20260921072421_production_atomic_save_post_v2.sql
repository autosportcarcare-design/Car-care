-- 20260921072421  production_atomic_save_post_v2
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace function private.save_transaction_draft_v2(p_organization_id uuid,p_transaction jsonb,p_lines jsonb)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_uid uuid:=auth.uid();
  v_company uuid:=coalesce(nullif(p_transaction->>'company_id','')::uuid,private.default_company_id(p_organization_id));
  v_branch uuid:=coalesce(nullif(p_transaction->>'branch_id','')::uuid,private.default_branch_id(p_organization_id,v_company));
  v_party uuid:=nullif(p_transaction->>'party_id','')::uuid;
  v_vehicle uuid:=nullif(p_transaction->>'vehicle_id','')::uuid;
  v_job uuid:=nullif(p_transaction->>'service_job_id','')::uuid;
  v_warehouse uuid:=nullif(p_transaction->>'warehouse_id','')::uuid;
  v_tx uuid;
  v_row public.transactions%rowtype;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  if not private.is_org_member(p_organization_id,v_uid) then raise exception 'organization access denied'; end if;
  if v_company is null or not exists(select 1 from public.companies where id=v_company and organization_id=p_organization_id and status='active') then raise exception 'active company required'; end if;
  if v_branch is not null and not exists(select 1 from public.branches where id=v_branch and organization_id=p_organization_id and company_id=v_company and status='active') then raise exception 'branch does not belong to company'; end if;
  if v_party is not null and not exists(select 1 from public.parties where id=v_party and organization_id=p_organization_id and company_id=v_company and status='active') then raise exception 'party does not belong to company'; end if;
  if v_vehicle is not null and not exists(select 1 from public.vehicles where id=v_vehicle and organization_id=p_organization_id and company_id=v_company and status='active' and (v_party is null or customer_id=v_party)) then raise exception 'vehicle does not belong to selected company/customer'; end if;
  if v_job is not null and not exists(select 1 from public.service_jobs where id=v_job and organization_id=p_organization_id and company_id=v_company and status<>'Cancelled' and (v_vehicle is null or vehicle_id=v_vehicle) and (v_party is null or customer_id=v_party)) then raise exception 'service job does not belong to selected company/customer/vehicle'; end if;
  if v_warehouse is not null and not exists(select 1 from public.warehouses where id=v_warehouse and organization_id=p_organization_id and company_id=v_company and status='active') then raise exception 'warehouse does not belong to company'; end if;

  v_tx:=private.save_transaction_draft(p_organization_id,p_transaction,p_lines);
  update public.transactions
     set company_id=v_company,branch_id=v_branch,vehicle_id=v_vehicle,service_job_id=v_job,updated_at=now()
   where id=v_tx and organization_id=p_organization_id;
  update public.transaction_lines set company_id=v_company where transaction_id=v_tx and organization_id=p_organization_id;

  select * into v_row from public.transactions where id=v_tx and organization_id=p_organization_id;
  if not found or v_row.status<>'draft' then raise exception 'draft verification failed'; end if;
  if v_row.company_id<>v_company or v_row.branch_id is distinct from v_branch then raise exception 'draft scope verification failed'; end if;
  if not exists(select 1 from public.transaction_lines where transaction_id=v_tx and organization_id=p_organization_id) then raise exception 'draft lines verification failed'; end if;

  return jsonb_build_object(
    'transaction_id',v_row.id,'status',v_row.status,'company_id',v_row.company_id,'branch_id',v_row.branch_id,
    'grand_total',v_row.grand_total,'line_count',(select count(*) from public.transaction_lines where transaction_id=v_tx and organization_id=p_organization_id),
    'verified',true
  );
end $$;
revoke all on function private.save_transaction_draft_v2(uuid,jsonb,jsonb) from public,anon,authenticated;

create or replace function public.save_transaction_draft_v2(p_organization_id uuid,p_transaction jsonb,p_lines jsonb)
returns jsonb language sql security definer set search_path='' as $$ select private.save_transaction_draft_v2($1,$2,$3); $$;
revoke all on function public.save_transaction_draft_v2(uuid,jsonb,jsonb) from public,anon;
grant execute on function public.save_transaction_draft_v2(uuid,jsonb,jsonb) to authenticated;

create or replace function private.save_and_post_transaction(p_organization_id uuid,p_transaction jsonb,p_lines jsonb,p_idempotency_key text)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_uid uuid:=auth.uid();
  v_draft jsonb;
  v_tx_id uuid;
  v_tx public.transactions%rowtype;
  v_party public.parties%rowtype;
  v_outstanding numeric(18,2):=0;
  v_post jsonb;
  v_journal_count integer:=0;
  v_stock_count integer:=0;
  v_open_count integer:=0;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key))<8 then raise exception 'idempotency key must contain at least 8 characters'; end if;

  select result into v_post from public.posting_requests where organization_id=p_organization_id and idempotency_key=p_idempotency_key;
  if v_post is not null then
    v_tx_id:=(v_post->>'transaction_id')::uuid;
    select * into v_tx from public.transactions where id=v_tx_id and organization_id=p_organization_id;
    if not found or v_tx.status<>'posted' then raise exception 'idempotency record verification failed'; end if;
    return v_post || jsonb_build_object('verified',true,'idempotent',true);
  end if;

  v_draft:=private.save_transaction_draft_v2(p_organization_id,p_transaction,p_lines);
  v_tx_id:=(v_draft->>'transaction_id')::uuid;
  select * into v_tx from public.transactions where id=v_tx_id and organization_id=p_organization_id for update;

  if v_tx.transaction_type in ('sale','service_sale','mixed_sale') and v_tx.party_id is not null then
    select * into v_party from public.parties where id=v_tx.party_id and organization_id=p_organization_id and company_id=v_tx.company_id;
    if coalesce(v_party.credit_limit,0)>0 then
      select coalesce(sum(greatest(original_amount-allocated_amount,0)),0) into v_outstanding
      from public.open_items where organization_id=p_organization_id and company_id=v_tx.company_id and party_id=v_tx.party_id and status in ('open','partially_paid');
      if round(v_outstanding+v_tx.grand_total,2)>v_party.credit_limit then raise exception 'customer credit limit exceeded'; end if;
    end if;
  end if;

  v_post:=private.post_transaction(v_tx_id,p_idempotency_key);

  select * into v_tx from public.transactions where id=v_tx_id and organization_id=p_organization_id;
  if not found or v_tx.status<>'posted' or v_tx.document_no is null then raise exception 'post verification failed'; end if;
  select count(*) into v_journal_count from public.journals where transaction_id=v_tx_id and organization_id=p_organization_id and status in ('posted','reversed');
  select count(*) into v_stock_count from public.stock_movements where transaction_id=v_tx_id and organization_id=p_organization_id;
  select count(*) into v_open_count from public.open_items where transaction_id=v_tx_id and organization_id=p_organization_id;
  if v_tx.transaction_type<>'quotation' and v_journal_count=0 then raise exception 'journal verification failed'; end if;

  return v_post || jsonb_build_object(
    'verified',true,
    'company_id',v_tx.company_id,
    'branch_id',v_tx.branch_id,
    'journal_count',v_journal_count,
    'stock_movement_count',v_stock_count,
    'ar_ap_count',v_open_count
  );
end $$;
revoke all on function private.save_and_post_transaction(uuid,jsonb,jsonb,text) from public,anon,authenticated;

create or replace function public.save_and_post_transaction(p_organization_id uuid,p_transaction jsonb,p_lines jsonb,p_idempotency_key text)
returns jsonb language sql security definer set search_path='' as $$ select private.save_and_post_transaction($1,$2,$3,$4); $$;
revoke all on function public.save_and_post_transaction(uuid,jsonb,jsonb,text) from public,anon;
grant execute on function public.save_and_post_transaction(uuid,jsonb,jsonb,text) to authenticated;

create or replace function public.get_transaction_verification(p_organization_id uuid,p_transaction_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
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
