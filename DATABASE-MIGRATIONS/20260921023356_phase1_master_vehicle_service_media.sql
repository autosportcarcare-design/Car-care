-- 20260921023356  phase1_master_vehicle_service_media
-- Applied to Supabase project pwzpljitxamthgqllgtu


update public.document_sequences set prefix='DO' where sequence_key='delivery_note';
update public.document_sequences set padding=6 where padding is null or padding<6;

alter table public.parties
  add column if not exists party_code text, add column if not exists reference_no text, add column if not exists spr_no text,
  add column if not exists legal_name text, add column if not exists display_name text, add column if not exists contact_person text,
  add column if not exists mobile text, add column if not exists alternate_mobile text, add column if not exists whatsapp text,
  add column if not exists telephone text, add column if not exists alternate_email text, add column if not exists address_line1 text,
  add column if not exists address_line2 text, add column if not exists area text, add column if not exists city text,
  add column if not exists emirate text, add column if not exists country text default 'United Arab Emirates',
  add column if not exists postal_code text, add column if not exists opening_balance numeric(18,2) not null default 0,
  add column if not exists opening_balance_type text, add column if not exists notes text,
  add column if not exists archived_at timestamptz, add column if not exists updated_by uuid;
alter table public.parties drop constraint if exists parties_opening_balance_type_check;
alter table public.parties add constraint parties_opening_balance_type_check check (opening_balance_type is null or opening_balance_type in ('debit','credit'));
alter table public.parties drop constraint if exists parties_status_check;
alter table public.parties add constraint parties_status_check check (status in ('active','inactive','archived'));
create unique index if not exists parties_org_code_uq on public.parties(organization_id, lower(party_code)) where party_code is not null;
create index if not exists parties_search_idx on public.parties(organization_id, mobile, whatsapp, tax_registration_no, spr_no, reference_no);

create table if not exists public.vehicles (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid not null references public.parties(id),
  vehicle_code text, make text, model text, variant text, year text,
  plate_number text, registration_emirate text, chassis_vin text, engine_number text,
  mileage numeric(12,0), colour text, registration_expiry date, insurance_provider text, insurance_expiry date,
  notes text, status text not null default 'active' check (status in ('active','inactive','archived')),
  created_by uuid default auth.uid(), created_at timestamptz not null default now(),
  updated_by uuid, updated_at timestamptz not null default now()
);
create unique index if not exists vehicles_org_code_uq on public.vehicles(organization_id, lower(vehicle_code)) where vehicle_code is not null;
create index if not exists vehicles_customer_idx on public.vehicles(organization_id, customer_id);
create index if not exists vehicles_search_idx on public.vehicles(organization_id, plate_number, chassis_vin);
alter table public.vehicles enable row level security;
drop policy if exists vehicles_select on public.vehicles;
drop policy if exists vehicles_insert on public.vehicles;
drop policy if exists vehicles_update on public.vehicles;
create policy vehicles_select on public.vehicles for select using (private.has_permission(organization_id,(select auth.uid()),'masters.view'));
create policy vehicles_insert on public.vehicles for insert with check (private.has_permission(organization_id,(select auth.uid()),'masters.create') and created_by=(select auth.uid()));
create policy vehicles_update on public.vehicles for update using (private.has_permission(organization_id,(select auth.uid()),'masters.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'masters.edit'));

create table if not exists public.vehicle_mileage_history (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  mileage numeric(12,0) not null check (mileage>=0), source text not null default 'manual',
  service_job_id uuid references public.service_jobs(id),
  recorded_by uuid default auth.uid(), recorded_at timestamptz not null default now()
);
alter table public.vehicle_mileage_history enable row level security;
drop policy if exists vmh_select on public.vehicle_mileage_history;
drop policy if exists vmh_insert on public.vehicle_mileage_history;
create policy vmh_select on public.vehicle_mileage_history for select using (private.has_permission(organization_id,(select auth.uid()),'masters.view'));
create policy vmh_insert on public.vehicle_mileage_history for insert with check (private.is_org_member(organization_id,(select auth.uid())));

create or replace function private.track_vehicle_mileage() returns trigger language plpgsql set search_path='' as $$
begin
  if new.mileage is not null and (tg_op='INSERT' or new.mileage is distinct from old.mileage) then
    insert into public.vehicle_mileage_history(organization_id,vehicle_id,mileage,source,recorded_by)
    values(new.organization_id,new.id,new.mileage,lower(tg_op),auth.uid());
  end if;
  return null;
end $$;
drop trigger if exists trg_vehicle_mileage on public.vehicles;
create trigger trg_vehicle_mileage after insert or update on public.vehicles for each row execute function private.track_vehicle_mileage();

alter table public.service_jobs
  add column if not exists vehicle_id uuid references public.vehicles(id), add column if not exists customer_phone text,
  add column if not exists assigned_staff uuid[] default '{}', add column if not exists notes text,
  add column if not exists delivered_at timestamptz;
alter table public.service_jobs drop constraint if exists service_jobs_status_check;
alter table public.service_jobs add constraint service_jobs_status_check check (status in
 ('draft','open','inspection','waiting_customer','in_progress','waiting','waiting_parts','completed','invoiced','delivered','cancelled'));
alter table public.service_job_tasks
  add column if not exists category text default 'service',
  add column if not exists sale_price numeric(18,2) not null default 0,
  add column if not exists actual_cost numeric(18,2) not null default 0;
alter table public.service_job_tasks drop constraint if exists service_job_tasks_category_check;
alter table public.service_job_tasks add constraint service_job_tasks_category_check check (category in
 ('service','labour','mechanical','electrical','paint','body_repair','polishing','detailing','ceramic','ppf','wrapping','tinting','interior','outside_work','additional_work','inspection','custom'));

alter table public.attachments
  add column if not exists customer_id uuid references public.parties(id), add column if not exists vehicle_id uuid references public.vehicles(id),
  add column if not exists service_job_id uuid references public.service_jobs(id), add column if not exists transaction_id uuid references public.transactions(id),
  add column if not exists caption text, add column if not exists deleted_at timestamptz, add column if not exists deleted_by uuid;
create index if not exists attachments_links_idx on public.attachments(organization_id, service_job_id, vehicle_id, customer_id, transaction_id);

alter table public.transactions
  add column if not exists vehicle_id uuid references public.vehicles(id),
  add column if not exists service_job_id uuid references public.service_jobs(id),
  add column if not exists media_snapshot jsonb;
alter table public.transactions drop constraint if exists transactions_transaction_type_check;
alter table public.transactions add constraint transactions_transaction_type_check check (transaction_type in
 ('sale','service_sale','mixed_sale','purchase','purchase_order','quotation','delivery_note','expense','income','receipt','payment',
  'customer_refund','supplier_refund','credit_note','debit_note','stock_adjustment','capital','drawing','journal','contra','transfer','opening_balance'));

create table if not exists public.transaction_media (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  transaction_id uuid not null references public.transactions(id) on delete cascade,
  attachment_id uuid not null references public.attachments(id),
  category text not null, sort_order integer not null default 0,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(),
  unique (transaction_id, attachment_id)
);
alter table public.transaction_media enable row level security;
drop policy if exists tm_select on public.transaction_media;
drop policy if exists tm_insert on public.transaction_media;
drop policy if exists tm_delete on public.transaction_media;
create policy tm_select on public.transaction_media for select using (private.is_org_member(organization_id,(select auth.uid())));
create policy tm_insert on public.transaction_media for insert with check (private.is_org_member(organization_id,(select auth.uid())));
create policy tm_delete on public.transaction_media for delete using (private.is_org_member(organization_id,(select auth.uid())));

create or replace function private.guard_posted_transaction_media() returns trigger language plpgsql set search_path='' as $$
declare v_status text;
begin
  select status into v_status from public.transactions where id=coalesce(new.transaction_id,old.transaction_id);
  if v_status in ('posted','void') then raise exception 'photos on a posted invoice cannot be changed'; end if;
  return coalesce(new,old);
end $$;
drop trigger if exists trg_guard_transaction_media on public.transaction_media;
create trigger trg_guard_transaction_media before insert or update or delete on public.transaction_media for each row execute function private.guard_posted_transaction_media();

create or replace function private.capture_media_snapshot() returns trigger language plpgsql set search_path='' as $$
begin
  if new.status='posted' and old.status is distinct from 'posted' then
    new.media_snapshot := coalesce((select jsonb_agg(jsonb_build_object('attachment_id',a.id,'category',tm.category,'storage_path',a.storage_path,
        'file_name',a.file_name,'mime_type',a.mime_type,'caption',a.caption) order by tm.sort_order)
      from public.transaction_media tm join public.attachments a on a.id=tm.attachment_id where tm.transaction_id=new.id),'[]'::jsonb);
  end if;
  return new;
end $$;
drop trigger if exists trg_capture_media_snapshot on public.transactions;
create trigger trg_capture_media_snapshot before update on public.transactions for each row execute function private.capture_media_snapshot();
;
