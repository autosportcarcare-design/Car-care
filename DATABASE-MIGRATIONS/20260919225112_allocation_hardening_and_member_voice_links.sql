-- 20260919225112  allocation_hardening_and_member_voice_links
-- Applied to Supabase project pwzpljitxamthgqllgtu

create or replace function private.allocate_open_item(p_payment_transaction_id uuid, p_open_item_id uuid, p_amount numeric)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid:=auth.uid();
  v_pay public.transactions%rowtype;
  v_open public.open_items%rowtype;
  v_id uuid;
  v_new numeric;
  v_payment_allocated numeric;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  if p_amount<=0 then raise exception 'allocation amount must be positive'; end if;
  select * into v_pay from public.transactions where id=p_payment_transaction_id and status='posted' for update;
  if not found or v_pay.transaction_type not in ('receipt','payment') then raise exception 'posted receipt/payment required'; end if;
  if not private.has_permission(v_pay.organization_id,v_uid,'transaction.post') then raise exception 'allocation permission denied'; end if;
  select * into v_open from public.open_items where id=p_open_item_id and organization_id=v_pay.organization_id for update;
  if not found or v_open.status='void' then raise exception 'open item not available'; end if;
  if (v_pay.transaction_type='receipt' and v_open.item_type<>'receivable') or (v_pay.transaction_type='payment' and v_open.item_type<>'payable') then raise exception 'allocation type mismatch'; end if;
  if v_pay.party_id is null or v_pay.party_id<>v_open.party_id then raise exception 'payment party does not match open item party'; end if;
  select coalesce(sum(amount),0) into v_payment_allocated from public.allocations where payment_transaction_id=v_pay.id and organization_id=v_pay.organization_id;
  if v_payment_allocated+p_amount>v_pay.grand_total then raise exception 'allocation exceeds receipt/payment amount'; end if;
  v_new:=v_open.allocated_amount+p_amount;
  if v_new>v_open.original_amount then raise exception 'allocation exceeds open balance'; end if;
  insert into public.allocations(organization_id,payment_transaction_id,open_item_id,amount,created_by) values(v_pay.organization_id,v_pay.id,v_open.id,p_amount,v_uid) returning id into v_id;
  update public.open_items set allocated_amount=v_new,status=case when v_new=v_open.original_amount then 'settled' else 'partially_paid' end where id=v_open.id;
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values) values(v_pay.organization_id,v_uid,'allocation.created','allocation',v_id::text,jsonb_build_object('open_item_id',v_open.id,'amount',p_amount));
  return v_id;
end;
$$;

alter table public.voice_recordings add column if not exists service_job_id uuid;
alter table public.voice_recordings drop constraint if exists voice_recordings_service_job_id_organization_id_fkey;
alter table public.voice_recordings add constraint voice_recordings_service_job_id_organization_id_fkey foreign key(service_job_id,organization_id) references public.service_jobs(id,organization_id) on delete set null;
create index if not exists voice_recordings_service_job_org_idx on public.voice_recordings(service_job_id,organization_id);

create or replace function private.list_organization_members(p_org uuid)
returns table(user_id uuid,email text,role_id uuid,role_name text,status text)
language plpgsql
security definer
set search_path=''
as $$
declare v_uid uuid:=auth.uid();
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if not private.has_permission(p_org,v_uid,'organization.admin') then raise exception 'Permission denied'; end if;
  return query
  select m.user_id,u.email::text,m.role_id,r.name,m.status
  from public.organization_members m
  join auth.users u on u.id=m.user_id
  join public.organization_roles r on r.id=m.role_id and r.organization_id=m.organization_id
  where m.organization_id=p_org
  order by lower(coalesce(u.email,''));
end;
$$;

create or replace function public.list_organization_members(p_org uuid)
returns table(user_id uuid,email text,role_id uuid,role_name text,status text)
language sql
set search_path=''
as $$ select * from private.list_organization_members($1); $$;

revoke all on function public.list_organization_members(uuid) from public,anon;
grant execute on function public.list_organization_members(uuid) to authenticated;;
