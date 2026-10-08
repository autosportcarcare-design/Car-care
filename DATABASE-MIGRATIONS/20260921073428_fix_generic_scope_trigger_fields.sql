-- 20260921073428  fix_generic_scope_trigger_fields
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace function private.fill_company_scope() returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_company uuid; v_parent uuid;
begin
  if tg_table_name in ('transaction_lines','journals','stock_movements','open_items','transaction_media','posting_requests') then
    v_parent:=nullif(to_jsonb(new)->>'transaction_id','')::uuid;
    if v_parent is not null then select company_id into v_company from public.transactions where id=v_parent and organization_id=new.organization_id; end if;
  elsif tg_table_name='journal_lines' then
    v_parent:=nullif(to_jsonb(new)->>'journal_id','')::uuid;
    if v_parent is not null then select company_id into v_company from public.journals where id=v_parent and organization_id=new.organization_id; end if;
  elsif tg_table_name='allocations' then
    v_parent:=nullif(to_jsonb(new)->>'payment_transaction_id','')::uuid;
    if v_parent is not null then select company_id into v_company from public.transactions where id=v_parent and organization_id=new.organization_id; end if;
  elsif tg_table_name='service_job_tasks' then
    v_parent:=nullif(to_jsonb(new)->>'service_job_id','')::uuid;
    if v_parent is not null then select company_id into v_company from public.service_jobs where id=v_parent and organization_id=new.organization_id; end if;
  elsif tg_table_name='document_profile_versions' then
    v_parent:=nullif(to_jsonb(new)->>'document_profile_id','')::uuid;
    if v_parent is not null then select company_id into v_company from public.document_profiles where id=v_parent and organization_id=new.organization_id; end if;
  else
    v_company:=new.company_id;
  end if;
  new.company_id:=coalesce(v_company,new.company_id,private.default_company_id(new.organization_id));
  if new.company_id is null then raise exception 'No active company configured for organization'; end if;
  if not exists(select 1 from public.companies c where c.id=new.company_id and c.organization_id=new.organization_id and c.status='active') then raise exception 'Company does not belong to organization'; end if;
  return new;
end $$;

create or replace function private.fill_branch_scope() returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_branch uuid; v_parent uuid;
begin
  if tg_table_name='stock_movements' then
    v_parent:=nullif(to_jsonb(new)->>'transaction_id','')::uuid;
    if v_parent is not null then select branch_id into v_branch from public.transactions where id=v_parent and organization_id=new.organization_id; end if;
  else
    v_branch:=new.branch_id;
  end if;
  new.branch_id:=coalesce(v_branch,new.branch_id,private.default_branch_id(new.organization_id,new.company_id));
  if new.branch_id is not null and not exists(select 1 from public.branches b where b.id=new.branch_id and b.organization_id=new.organization_id and b.company_id=new.company_id and b.status='active') then raise exception 'Branch does not belong to company'; end if;
  return new;
end $$;;
