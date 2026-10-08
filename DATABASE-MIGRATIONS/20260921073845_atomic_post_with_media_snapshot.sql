-- 20260921073845  atomic_post_with_media_snapshot
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace function private.save_and_post_transaction_with_media(
  p_organization_id uuid,p_transaction jsonb,p_lines jsonb,p_media_ids uuid[],p_idempotency_key text
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_uid uuid:=auth.uid(); v_draft jsonb; v_tx_id uuid; v_tx public.transactions%rowtype; v_party public.parties%rowtype;
  v_outstanding numeric(18,2):=0; v_post jsonb; v_journal_count int:=0; v_stock_count int:=0; v_open_count int:=0;
  v_attachment public.attachments%rowtype; v_media uuid; v_sort int:=0;
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

  delete from public.transaction_media where transaction_id=v_tx_id and organization_id=p_organization_id;
  if p_media_ids is not null then
    foreach v_media in array p_media_ids loop
      select * into v_attachment from public.attachments
      where id=v_media and organization_id=p_organization_id and company_id=v_tx.company_id and deleted_at is null;
      if not found then raise exception 'selected media is unavailable or outside the transaction company'; end if;
      if v_tx.service_job_id is not null and v_attachment.service_job_id is distinct from v_tx.service_job_id then raise exception 'selected media does not belong to selected service job'; end if;
      v_sort:=v_sort+1;
      insert into public.transaction_media(organization_id,company_id,transaction_id,attachment_id,category,sort_order,created_by)
      values(p_organization_id,v_tx.company_id,v_tx_id,v_attachment.id,upper(coalesce(v_attachment.category,'SUPPORTING')),v_sort,v_uid);
    end loop;
  end if;

  v_post:=private.post_transaction(v_tx_id,p_idempotency_key);
  select * into v_tx from public.transactions where id=v_tx_id and organization_id=p_organization_id;
  if not found or v_tx.status<>'posted' or v_tx.document_no is null then raise exception 'post verification failed'; end if;
  select count(*) into v_journal_count from public.journals where transaction_id=v_tx_id and organization_id=p_organization_id and status in ('posted','reversed');
  select count(*) into v_stock_count from public.stock_movements where transaction_id=v_tx_id and organization_id=p_organization_id;
  select count(*) into v_open_count from public.open_items where transaction_id=v_tx_id and organization_id=p_organization_id;
  if v_tx.transaction_type<>'quotation' and v_journal_count=0 then raise exception 'journal verification failed'; end if;
  if coalesce(array_length(p_media_ids,1),0) <> (select count(*) from public.transaction_media where transaction_id=v_tx_id and organization_id=p_organization_id) then raise exception 'media link verification failed'; end if;

  return v_post || jsonb_build_object('verified',true,'company_id',v_tx.company_id,'branch_id',v_tx.branch_id,
    'journal_count',v_journal_count,'stock_movement_count',v_stock_count,'ar_ap_count',v_open_count,
    'media_count',(select count(*) from public.transaction_media where transaction_id=v_tx_id and organization_id=p_organization_id));
end $$;
revoke all on function private.save_and_post_transaction_with_media(uuid,jsonb,jsonb,uuid[],text) from public,anon;
grant execute on function private.save_and_post_transaction_with_media(uuid,jsonb,jsonb,uuid[],text) to authenticated;

create or replace function public.save_and_post_transaction_with_media(
  p_organization_id uuid,p_transaction jsonb,p_lines jsonb,p_media_ids uuid[],p_idempotency_key text
) returns jsonb language sql security invoker set search_path=''
as $$ select private.save_and_post_transaction_with_media($1,$2,$3,$4,$5); $$;
revoke all on function public.save_and_post_transaction_with_media(uuid,jsonb,jsonb,uuid[],text) from public,anon;
grant execute on function public.save_and_post_transaction_with_media(uuid,jsonb,jsonb,uuid[],text) to authenticated;;
