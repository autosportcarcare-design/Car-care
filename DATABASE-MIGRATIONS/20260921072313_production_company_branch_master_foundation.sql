-- 20260921072313  production_company_branch_master_foundation
-- Applied to Supabase project pwzpljitxamthgqllgtu

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists profiles_select_self on public.profiles;
create policy profiles_select_self on public.profiles for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self on public.profiles for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
grant select,insert,update on public.profiles to authenticated;

create table if not exists public.companies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  code text,
  name text not null,
  legal_name text,
  country text not null default 'United Arab Emirates',
  currency text not null default 'AED' check (length(currency)=3),
  tax_enabled boolean not null default false,
  tax_registration_no text,
  is_default boolean not null default false,
  status text not null default 'active' check (status in ('active','archived')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(id,organization_id)
);
create unique index if not exists companies_one_default_per_org on public.companies(organization_id) where is_default and status='active';
create unique index if not exists companies_org_code_unique on public.companies(organization_id,lower(code)) where code is not null;
alter table public.companies enable row level security;
drop policy if exists companies_select on public.companies;
create policy companies_select on public.companies for select to authenticated using (private.is_org_member(organization_id,(select auth.uid())));
drop policy if exists companies_insert on public.companies;
create policy companies_insert on public.companies for insert to authenticated with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
drop policy if exists companies_update on public.companies;
create policy companies_update on public.companies for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
grant select,insert,update on public.companies to authenticated;

create table if not exists public.branches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  company_id uuid not null,
  code text not null,
  name text not null,
  address text,
  is_default boolean not null default false,
  status text not null default 'active' check (status in ('active','archived')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(id,organization_id),
  unique(organization_id,company_id,code),
  foreign key(company_id,organization_id) references public.companies(id,organization_id) on delete cascade
);
create unique index if not exists branches_one_default_per_company on public.branches(company_id) where is_default and status='active';
alter table public.branches enable row level security;
drop policy if exists branches_select on public.branches;
create policy branches_select on public.branches for select to authenticated using (private.is_org_member(organization_id,(select auth.uid())));
drop policy if exists branches_insert on public.branches;
create policy branches_insert on public.branches for insert to authenticated with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
drop policy if exists branches_update on public.branches;
create policy branches_update on public.branches for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
grant select,insert,update on public.branches to authenticated;

insert into public.companies(organization_id,code,name,legal_name,country,currency,tax_enabled,tax_registration_no,is_default,created_by)
select o.id,'MAIN',o.name,s.legal_name,'United Arab Emirates',coalesce(nullif(s.currency,''),'AED'),coalesce(s.tax_enabled,false),s.tax_registration_no,true,o.created_by
from public.organizations o
left join public.organization_settings s on s.organization_id=o.id
where not exists(select 1 from public.companies c where c.organization_id=o.id);

insert into public.branches(organization_id,company_id,code,name,is_default,created_by)
select c.organization_id,c.id,'MAIN','Main Branch',true,c.created_by
from public.companies c
where c.is_default and not exists(select 1 from public.branches b where b.company_id=c.id);

create or replace function private.default_company_id(p_org uuid) returns uuid
language sql stable security definer set search_path=''
as $$ select id from public.companies where organization_id=p_org and is_default and status='active' order by created_at limit 1 $$;
create or replace function private.default_branch_id(p_org uuid,p_company uuid) returns uuid
language sql stable security definer set search_path=''
as $$ select id from public.branches where organization_id=p_org and company_id=p_company and is_default and status='active' order by created_at limit 1 $$;
revoke all on function private.default_company_id(uuid) from public,anon,authenticated;
revoke all on function private.default_branch_id(uuid,uuid) from public,anon,authenticated;

create or replace function private.bootstrap_company_structure() returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_company uuid;
begin
  insert into public.companies(organization_id,code,name,legal_name,country,currency,is_default,created_by)
  values(new.id,'MAIN',new.name,new.name,'United Arab Emirates','AED',true,new.created_by)
  returning id into v_company;
  insert into public.branches(organization_id,company_id,code,name,is_default,created_by)
  values(new.id,v_company,'MAIN','Main Branch',true,new.created_by);
  return new;
end $$;
revoke all on function private.bootstrap_company_structure() from public,anon,authenticated;
drop trigger if exists organizations_bootstrap_company_structure on public.organizations;
create trigger organizations_bootstrap_company_structure after insert on public.organizations for each row execute function private.bootstrap_company_structure();

alter table public.organization_settings alter column currency set default 'AED';
alter table public.organization_settings add column if not exists approval_workflow_enabled boolean not null default false;
alter table public.organization_settings add column if not exists country text not null default 'United Arab Emirates';

alter table public.warehouses add column if not exists company_id uuid;
alter table public.warehouses add column if not exists branch_id uuid;
alter table public.parties add column if not exists company_id uuid;
alter table public.vehicles add column if not exists company_id uuid;
alter table public.products add column if not exists company_id uuid;
alter table public.accounting_periods add column if not exists company_id uuid;
alter table public.accounts add column if not exists company_id uuid;
alter table public.tax_codes add column if not exists company_id uuid;
alter table public.payment_methods add column if not exists company_id uuid;
alter table public.transactions add column if not exists company_id uuid;
alter table public.transactions add column if not exists branch_id uuid;
alter table public.transaction_lines add column if not exists company_id uuid;
alter table public.journals add column if not exists company_id uuid;
alter table public.journal_lines add column if not exists company_id uuid;
alter table public.stock_balances add column if not exists company_id uuid;
alter table public.stock_movements add column if not exists company_id uuid;
alter table public.stock_movements add column if not exists branch_id uuid;
alter table public.open_items add column if not exists company_id uuid;
alter table public.allocations add column if not exists company_id uuid;
alter table public.service_jobs add column if not exists company_id uuid;
alter table public.service_jobs add column if not exists branch_id uuid;
alter table public.service_job_tasks add column if not exists company_id uuid;
alter table public.attachments add column if not exists company_id uuid;
alter table public.attachments add column if not exists branch_id uuid;
alter table public.transaction_media add column if not exists company_id uuid;
alter table public.document_profiles add column if not exists company_id uuid;
alter table public.document_profile_versions add column if not exists company_id uuid;
alter table public.posting_requests add column if not exists company_id uuid;
alter table public.audit_log add column if not exists company_id uuid;
alter table public.backup_manifests add column if not exists company_id uuid;

create or replace function private.fill_company_scope() returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_company uuid;
begin
  if tg_table_name='transaction_lines' and new.transaction_id is not null then select company_id into v_company from public.transactions where id=new.transaction_id and organization_id=new.organization_id;
  elsif tg_table_name='journals' and new.transaction_id is not null then select company_id into v_company from public.transactions where id=new.transaction_id and organization_id=new.organization_id;
  elsif tg_table_name='journal_lines' and new.journal_id is not null then select company_id into v_company from public.journals where id=new.journal_id and organization_id=new.organization_id;
  elsif tg_table_name='stock_movements' and new.transaction_id is not null then select company_id into v_company from public.transactions where id=new.transaction_id and organization_id=new.organization_id;
  elsif tg_table_name='open_items' and new.transaction_id is not null then select company_id into v_company from public.transactions where id=new.transaction_id and organization_id=new.organization_id;
  elsif tg_table_name='allocations' and new.payment_transaction_id is not null then select company_id into v_company from public.transactions where id=new.payment_transaction_id and organization_id=new.organization_id;
  elsif tg_table_name='service_job_tasks' and new.service_job_id is not null then select company_id into v_company from public.service_jobs where id=new.service_job_id and organization_id=new.organization_id;
  elsif tg_table_name='transaction_media' and new.transaction_id is not null then select company_id into v_company from public.transactions where id=new.transaction_id and organization_id=new.organization_id;
  elsif tg_table_name='document_profile_versions' and new.document_profile_id is not null then select company_id into v_company from public.document_profiles where id=new.document_profile_id and organization_id=new.organization_id;
  elsif tg_table_name='posting_requests' and new.transaction_id is not null then select company_id into v_company from public.transactions where id=new.transaction_id and organization_id=new.organization_id;
  else v_company:=new.company_id;
  end if;
  new.company_id:=coalesce(v_company,private.default_company_id(new.organization_id));
  if new.company_id is null then raise exception 'No active company configured for organization'; end if;
  if not exists(select 1 from public.companies c where c.id=new.company_id and c.organization_id=new.organization_id and c.status='active') then raise exception 'Company does not belong to organization'; end if;
  return new;
end $$;
revoke all on function private.fill_company_scope() from public,anon,authenticated;

create or replace function private.fill_branch_scope() returns trigger
language plpgsql security definer set search_path=''
as $$
declare v_branch uuid;
begin
  if tg_table_name='stock_movements' and new.transaction_id is not null then select branch_id into v_branch from public.transactions where id=new.transaction_id and organization_id=new.organization_id;
  else v_branch:=new.branch_id;
  end if;
  new.branch_id:=coalesce(v_branch,private.default_branch_id(new.organization_id,new.company_id));
  if new.branch_id is not null and not exists(select 1 from public.branches b where b.id=new.branch_id and b.organization_id=new.organization_id and b.company_id=new.company_id and b.status='active') then raise exception 'Branch does not belong to company'; end if;
  return new;
end $$;
revoke all on function private.fill_branch_scope() from public,anon,authenticated;

do $$
declare t text;
begin
  foreach t in array array['warehouses','parties','vehicles','products','accounting_periods','accounts','tax_codes','payment_methods','transactions','transaction_lines','journals','journal_lines','stock_balances','stock_movements','open_items','allocations','service_jobs','service_job_tasks','attachments','transaction_media','document_profiles','document_profile_versions','posting_requests','audit_log','backup_manifests']
  loop
    execute format('drop trigger if exists %I on public.%I','fill_company_scope_'||t,t);
    execute format('create trigger %I before insert on public.%I for each row execute function private.fill_company_scope()','fill_company_scope_'||t,t);
  end loop;
  foreach t in array array['warehouses','transactions','stock_movements','service_jobs','attachments']
  loop
    execute format('drop trigger if exists %I on public.%I','fill_branch_scope_'||t,t);
    execute format('create trigger %I before insert on public.%I for each row execute function private.fill_branch_scope()','fill_branch_scope_'||t,t);
  end loop;
end $$;

update public.warehouses x set company_id=private.default_company_id(x.organization_id) where company_id is null;
update public.parties x set company_id=private.default_company_id(x.organization_id) where company_id is null;
update public.vehicles x set company_id=private.default_company_id(x.organization_id) where company_id is null;
update public.products x set company_id=private.default_company_id(x.organization_id) where company_id is null;
update public.accounting_periods x set company_id=private.default_company_id(x.organization_id) where company_id is null;
update public.accounts x set company_id=private.default_company_id(x.organization_id) where company_id is null;
update public.tax_codes x set company_id=private.default_company_id(x.organization_id) where company_id is null;
update public.payment_methods x set company_id=private.default_company_id(x.organization_id) where company_id is null;
update public.transactions x set company_id=private.default_company_id(x.organization_id) where company_id is null;
update public.transaction_lines x set company_id=coalesce((select t.company_id from public.transactions t where t.id=x.transaction_id),private.default_company_id(x.organization_id)) where company_id is null;
update public.journals x set company_id=coalesce((select t.company_id from public.transactions t where t.id=x.transaction_id),private.default_company_id(x.organization_id)) where company_id is null;
update public.journal_lines x set company_id=coalesce((select j.company_id from public.journals j where j.id=x.journal_id),private.default_company_id(x.organization_id)) where company_id is null;
update public.stock_balances x set company_id=private.default_company_id(x.organization_id) where company_id is null;
update public.stock_movements x set company_id=coalesce((select t.company_id from public.transactions t where t.id=x.transaction_id),private.default_company_id(x.organization_id)) where company_id is null;
update public.open_items x set company_id=coalesce((select t.company_id from public.transactions t where t.id=x.transaction_id),private.default_company_id(x.organization_id)) where company_id is null;
update public.allocations x set company_id=coalesce((select t.company_id from public.transactions t where t.id=x.payment_transaction_id),private.default_company_id(x.organization_id)) where company_id is null;
update public.service_jobs x set company_id=private.default_company_id(x.organization_id) where company_id is null;
update public.service_job_tasks x set company_id=coalesce((select s.company_id from public.service_jobs s where s.id=x.service_job_id),private.default_company_id(x.organization_id)) where company_id is null;
update public.attachments x set company_id=private.default_company_id(x.organization_id) where company_id is null;
update public.transaction_media x set company_id=coalesce((select t.company_id from public.transactions t where t.id=x.transaction_id),private.default_company_id(x.organization_id)) where company_id is null;
update public.document_profiles x set company_id=private.default_company_id(x.organization_id) where company_id is null;
update public.document_profile_versions x set company_id=coalesce((select p.company_id from public.document_profiles p where p.id=x.document_profile_id),private.default_company_id(x.organization_id)) where company_id is null;
update public.posting_requests x set company_id=coalesce((select t.company_id from public.transactions t where t.id=x.transaction_id),private.default_company_id(x.organization_id)) where company_id is null;
update public.audit_log x set company_id=private.default_company_id(x.organization_id) where company_id is null;
update public.backup_manifests x set company_id=private.default_company_id(x.organization_id) where company_id is null;

update public.warehouses x set branch_id=private.default_branch_id(x.organization_id,x.company_id) where branch_id is null;
update public.transactions x set branch_id=private.default_branch_id(x.organization_id,x.company_id) where branch_id is null;
update public.stock_movements x set branch_id=coalesce((select t.branch_id from public.transactions t where t.id=x.transaction_id),private.default_branch_id(x.organization_id,x.company_id)) where branch_id is null;
update public.service_jobs x set branch_id=private.default_branch_id(x.organization_id,x.company_id) where branch_id is null;
update public.attachments x set branch_id=private.default_branch_id(x.organization_id,x.company_id) where branch_id is null;

do $$
declare t text;
begin
  foreach t in array array['warehouses','parties','vehicles','products','accounting_periods','accounts','tax_codes','payment_methods','transactions','transaction_lines','journals','journal_lines','stock_balances','stock_movements','open_items','allocations','service_jobs','service_job_tasks','attachments','transaction_media','document_profiles','document_profile_versions','posting_requests','audit_log','backup_manifests']
  loop execute format('alter table public.%I alter column company_id set not null',t); end loop;
end $$;

alter table public.warehouses add constraint warehouses_company_scope_fk foreign key(company_id,organization_id) references public.companies(id,organization_id);
alter table public.warehouses add constraint warehouses_branch_scope_fk foreign key(branch_id,organization_id) references public.branches(id,organization_id);
alter table public.parties add constraint parties_company_scope_fk foreign key(company_id,organization_id) references public.companies(id,organization_id);
alter table public.vehicles add constraint vehicles_company_scope_fk foreign key(company_id,organization_id) references public.companies(id,organization_id);
alter table public.products add constraint products_company_scope_fk foreign key(company_id,organization_id) references public.companies(id,organization_id);
alter table public.transactions add constraint transactions_company_scope_fk foreign key(company_id,organization_id) references public.companies(id,organization_id);
alter table public.transactions add constraint transactions_branch_scope_fk foreign key(branch_id,organization_id) references public.branches(id,organization_id);
alter table public.service_jobs add constraint service_jobs_company_scope_fk foreign key(company_id,organization_id) references public.companies(id,organization_id);
alter table public.service_jobs add constraint service_jobs_branch_scope_fk foreign key(branch_id,organization_id) references public.branches(id,organization_id);

alter table public.products add column if not exists barcode text;
alter table public.products add column if not exists description text;
alter table public.products add column if not exists purchase_price numeric(18,2) not null default 0 check (purchase_price>=0);
alter table public.products add column if not exists minimum_stock numeric(18,4) not null default 0;
alter table public.products add column if not exists reorder_quantity numeric(18,4) not null default 0;
alter table public.products add column if not exists default_warehouse_id uuid;
alter table public.products add column if not exists photo_attachment_id uuid;
alter table public.products add column if not exists notes text;

create table if not exists public.product_categories (
  id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade,
  company_id uuid not null, parent_id uuid references public.product_categories(id), code text, name text not null, status text not null default 'active',
  created_by uuid references auth.users(id), created_at timestamptz not null default now(), unique(id,organization_id),
  foreign key(company_id,organization_id) references public.companies(id,organization_id)
);
alter table public.products add column if not exists category_id uuid;
alter table public.products add constraint products_category_fk foreign key(category_id,organization_id) references public.product_categories(id,organization_id);
create table if not exists public.product_prices (
  id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade,
  company_id uuid not null, product_id uuid not null, price_type text not null default 'sale', amount numeric(18,2) not null check(amount>=0),
  effective_from date not null default current_date, effective_to date, created_by uuid references auth.users(id), created_at timestamptz not null default now(),
  foreign key(company_id,organization_id) references public.companies(id,organization_id), foreign key(product_id,organization_id) references public.products(id,organization_id)
);

create table if not exists public.party_roles (
  organization_id uuid not null references public.organizations(id) on delete cascade, company_id uuid not null, party_id uuid not null, role text not null check(role in ('customer','supplier')),
  created_at timestamptz not null default now(), primary key(party_id,role), foreign key(company_id,organization_id) references public.companies(id,organization_id), foreign key(party_id,organization_id) references public.parties(id,organization_id)
);
create table if not exists public.party_contacts (
  id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade, company_id uuid not null,
  party_id uuid not null, contact_type text not null, label text, value text not null, is_primary boolean not null default false, created_at timestamptz not null default now(),
  foreign key(company_id,organization_id) references public.companies(id,organization_id), foreign key(party_id,organization_id) references public.parties(id,organization_id)
);
create table if not exists public.party_addresses (
  id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade, company_id uuid not null,
  party_id uuid not null, address_type text not null default 'billing', line1 text, line2 text, area text, city text, emirate text, country text not null default 'United Arab Emirates', postal_code text, is_primary boolean not null default false, created_at timestamptz not null default now(),
  foreign key(company_id,organization_id) references public.companies(id,organization_id), foreign key(party_id,organization_id) references public.parties(id,organization_id)
);
create table if not exists public.party_notes (
  id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade, company_id uuid not null,
  party_id uuid not null, note text not null, created_by uuid references auth.users(id), created_at timestamptz not null default now(),
  foreign key(company_id,organization_id) references public.companies(id,organization_id), foreign key(party_id,organization_id) references public.parties(id,organization_id)
);

insert into public.party_roles(organization_id,company_id,party_id,role)
select organization_id,company_id,id,case when party_type in ('supplier') then 'supplier' else 'customer' end from public.parties on conflict do nothing;
insert into public.party_roles(organization_id,company_id,party_id,role)
select organization_id,company_id,id,'supplier' from public.parties where party_type in ('both','customer_supplier') on conflict do nothing;

create table if not exists public.account_groups (
  id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade, company_id uuid not null,
  code text, name text not null, group_type text not null check(group_type in ('asset','liability','equity','income','expense','cogs')), parent_id uuid references public.account_groups(id),
  status text not null default 'active', created_at timestamptz not null default now(), unique(id,organization_id), foreign key(company_id,organization_id) references public.companies(id,organization_id)
);
alter table public.accounts add column if not exists group_id uuid;
alter table public.accounts add constraint accounts_group_fk foreign key(group_id,organization_id) references public.account_groups(id,organization_id);

create table if not exists public.service_job_items (
  id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade, company_id uuid not null,
  service_job_id uuid not null, product_id uuid, item_type text not null default 'part', description text not null, quantity numeric(18,4) not null default 1 check(quantity>0),
  unit_price numeric(18,2) not null default 0, unit_cost numeric(18,6) not null default 0, notes text, created_by uuid references auth.users(id), created_at timestamptz not null default now(),
  foreign key(company_id,organization_id) references public.companies(id,organization_id), foreign key(service_job_id,organization_id) references public.service_jobs(id,organization_id), foreign key(product_id,organization_id) references public.products(id,organization_id)
);
create table if not exists public.service_job_status_history (
  id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade, company_id uuid not null,
  service_job_id uuid not null, from_status text, to_status text not null, note text, changed_by uuid references auth.users(id), changed_at timestamptz not null default now(),
  foreign key(company_id,organization_id) references public.companies(id,organization_id), foreign key(service_job_id,organization_id) references public.service_jobs(id,organization_id)
);
create or replace function private.capture_service_job_status_history() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='INSERT' or old.status is distinct from new.status then
    insert into public.service_job_status_history(organization_id,company_id,service_job_id,from_status,to_status,changed_by)
    values(new.organization_id,new.company_id,new.id,case when tg_op='INSERT' then null else old.status end,new.status,auth.uid());
  end if; return new;
end $$;
revoke all on function private.capture_service_job_status_history() from public,anon,authenticated;
drop trigger if exists service_jobs_status_history on public.service_jobs;
create trigger service_jobs_status_history after insert or update of status on public.service_jobs for each row execute function private.capture_service_job_status_history();

create table if not exists public.document_snapshots (
  id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade, company_id uuid not null,
  transaction_id uuid not null, document_no text, organization_snapshot jsonb not null, party_snapshot jsonb not null, document_profile_snapshot jsonb not null, media_snapshot jsonb,
  created_at timestamptz not null default now(), unique(transaction_id), foreign key(company_id,organization_id) references public.companies(id,organization_id), foreign key(transaction_id,organization_id) references public.transactions(id,organization_id)
);
create or replace function private.capture_document_snapshot_row() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.status='posted' and (tg_op='INSERT' or old.status is distinct from 'posted') then
    insert into public.document_snapshots(organization_id,company_id,transaction_id,document_no,organization_snapshot,party_snapshot,document_profile_snapshot,media_snapshot)
    values(new.organization_id,new.company_id,new.id,new.document_no,new.organization_snapshot,new.party_snapshot,new.document_profile_snapshot,new.media_snapshot)
    on conflict(transaction_id) do nothing;
  end if; return new;
end $$;
revoke all on function private.capture_document_snapshot_row() from public,anon,authenticated;
drop trigger if exists transactions_document_snapshot_row on public.transactions;
create trigger transactions_document_snapshot_row after insert or update of status on public.transactions for each row execute function private.capture_document_snapshot_row();

create or replace function private.fill_child_company_scope() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.company_id is null then new.company_id:=private.default_company_id(new.organization_id); end if;
  if new.company_id is null or not exists(select 1 from public.companies c where c.id=new.company_id and c.organization_id=new.organization_id and c.status='active') then raise exception 'Valid company required'; end if;
  return new;
end $$;
revoke all on function private.fill_child_company_scope() from public,anon,authenticated;
do $$ declare t text; begin
  foreach t in array array['product_categories','product_prices','party_roles','party_contacts','party_addresses','party_notes','account_groups','service_job_items','service_job_status_history','document_snapshots'] loop
    execute format('drop trigger if exists %I on public.%I','fill_child_company_scope_'||t,t);
    execute format('create trigger %I before insert on public.%I for each row execute function private.fill_child_company_scope()','fill_child_company_scope_'||t,t);
  end loop;
end $$;

do $$ declare t text; begin
  foreach t in array array['product_categories','product_prices','party_roles','party_contacts','party_addresses','party_notes','account_groups','service_job_items','service_job_status_history','document_snapshots'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('drop policy if exists %I on public.%I','scope_select_'||t,t);
    execute format('create policy %I on public.%I for select to authenticated using (private.is_org_member(organization_id,(select auth.uid())))','scope_select_'||t,t);
    execute format('drop policy if exists %I on public.%I','scope_insert_'||t,t);
    execute format('create policy %I on public.%I for insert to authenticated with check (private.is_org_member(organization_id,(select auth.uid())))','scope_insert_'||t,t);
    execute format('drop policy if exists %I on public.%I','scope_update_'||t,t);
    execute format('create policy %I on public.%I for update to authenticated using (private.is_org_member(organization_id,(select auth.uid()))) with check (private.is_org_member(organization_id,(select auth.uid())))','scope_update_'||t,t);
    execute format('grant select,insert,update on public.%I to authenticated',t);
  end loop;
end $$;

create or replace view public.warehouse_stock with (security_invoker=true) as select * from public.stock_balances;
create or replace view public.stock_movement_lines with (security_invoker=true) as select * from public.stock_movements;
create or replace view public.ar_ap_documents with (security_invoker=true) as select * from public.open_items;
create or replace view public.payment_allocations with (security_invoker=true) as select * from public.allocations;
create or replace view public.media with (security_invoker=true) as select * from public.attachments where deleted_at is null;
create or replace view public.audit_events with (security_invoker=true) as select * from public.audit_log;
create or replace view public.backup_metadata with (security_invoker=true) as select * from public.backup_manifests;
grant select on public.warehouse_stock,public.stock_movement_lines,public.ar_ap_documents,public.payment_allocations,public.media,public.audit_events,public.backup_metadata to authenticated;

insert into public.permission_catalog(key,description) values
 ('company.manage','Create and manage companies and branches'),
 ('cost.view','View costs'),('reports.view','View reports'),('photos.manage','Manage photos and attachments'),('users.manage','Manage users and roles'),('documents.print','Print documents'),('documents.export','Export documents'),('stock.transfer','Transfer stock')
on conflict(key) do nothing;
insert into public.organization_role_permissions(organization_id,role_id,permission_key)
select r.organization_id,r.id,p.key from public.organization_roles r cross join public.permission_catalog p where r.name='Owner' on conflict do nothing;
insert into public.organization_role_permissions(organization_id,role_id,permission_key)
select r.organization_id,r.id,p.key from public.organization_roles r join public.permission_catalog p on p.key in ('company.manage','cost.view','reports.view','photos.manage','users.manage','documents.print','documents.export','stock.transfer') where r.name='Admin' on conflict do nothing;;
