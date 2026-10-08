-- 20260919074754  v2_multi_tenant_foundation
-- Applied to Supabase project pwzpljitxamthgqllgtu

create extension if not exists pgcrypto;
create schema if not exists private;

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 120),
  status text not null default 'active' check (status in ('active','suspended','archived')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, name)
);

create table public.permission_catalog (
  key text primary key,
  description text not null
);

insert into public.permission_catalog(key,description) values
('organization.view','View organization'),('organization.admin','Administer organization'),
('settings.view','View settings'),('settings.edit','Edit settings'),
('masters.view','View master records'),('masters.create','Create master records'),('masters.edit','Edit master records'),
('transaction.view','View transactions'),('transaction.create','Create drafts'),('transaction.edit','Edit drafts'),
('transaction.approve','Approve transactions'),('transaction.post','Post transactions'),('transaction.void','Void posted transactions'),('transaction.correct_posted','Correct posted transactions'),
('transaction.print','Print documents'),('transaction.export','Export documents'),
('accounting.view','View accounting'),('accounting.journal_create','Create journals'),
('stock.view','View stock'),('stock.adjust','Adjust stock'),('stock.negative_override','Override negative stock warnings'),
('profit.view','View cost and profit'),('documents.design','Manage document profiles'),
('audit.view','View audit trail'),('backup.create','Create backup'),('backup.restore','Restore backup')
on conflict do nothing;

create table public.organization_roles (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  is_system boolean not null default false,
  created_at timestamptz not null default now(),
  unique (organization_id, name),
  unique (id, organization_id)
);

create table public.organization_role_permissions (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  role_id uuid not null,
  permission_key text not null references public.permission_catalog(key) on delete cascade,
  primary key (organization_id, role_id, permission_key),
  foreign key (role_id, organization_id) references public.organization_roles(id, organization_id) on delete cascade
);

create table public.organization_members (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role_id uuid not null,
  status text not null default 'active' check (status in ('invited','active','suspended','removed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_id, user_id),
  foreign key (role_id, organization_id) references public.organization_roles(id, organization_id)
);

create table public.organization_settings (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  legal_name text,
  operating_name text,
  email text,
  phone text,
  address text,
  tax_registration_no text,
  currency text not null default 'USD' check (length(currency)=3),
  tax_enabled boolean not null default false,
  default_tax_rate numeric(9,4) not null default 0 check (default_tax_rate between 0 and 100),
  negative_stock_policy text not null default 'block' check (negative_stock_policy in ('block','warn','allow')),
  full_accounting_mode boolean not null default true,
  settings jsonb not null default '{}'::jsonb,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

create table public.parties (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  party_type text not null check (party_type in ('customer','supplier','both','other')),
  name text not null check (length(trim(name)) between 1 and 160),
  phone text,
  email text,
  address text,
  tax_registration_no text,
  credit_limit numeric(18,2),
  credit_days integer not null default 0 check (credit_days >= 0),
  status text not null default 'active' check (status in ('active','inactive')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, organization_id)
);

create table public.warehouses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  code text not null,
  name text not null,
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  unique (organization_id, code),
  unique (id, organization_id)
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  item_type text not null default 'inventory' check (item_type in ('inventory','non_inventory','service','labour','outside_work','package','expense_item')),
  sku text,
  name text not null,
  unit text not null default 'pcs',
  sale_price numeric(18,2) not null default 0,
  average_cost numeric(18,6) not null default 0,
  negative_stock_policy text check (negative_stock_policy is null or negative_stock_policy in ('block','warn','allow')),
  status text not null default 'active' check (status in ('active','inactive')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, sku),
  unique (id, organization_id)
);

create table public.tax_codes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  code text not null,
  name text not null,
  rate numeric(9,4) not null check (rate between 0 and 100),
  classification text not null default 'taxable' check (classification in ('taxable','zero_rated','exempt','out_of_scope')),
  inclusive boolean not null default false,
  input_recoverable_default boolean,
  effective_from date not null default current_date,
  effective_to date,
  status text not null default 'active' check (status in ('active','inactive')),
  unique (organization_id, code, effective_from),
  unique (id, organization_id),
  check (effective_to is null or effective_to >= effective_from)
);

create table public.accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  code text not null,
  name text not null,
  account_type text not null check (account_type in ('asset','liability','equity','income','cogs','expense')),
  parent_id uuid,
  system_key text,
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  unique (organization_id, code),
  unique (organization_id, system_key),
  unique (id, organization_id),
  foreign key (parent_id, organization_id) references public.accounts(id, organization_id)
);

create table public.payment_methods (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  account_id uuid,
  status text not null default 'active' check (status in ('active','inactive')),
  unique (organization_id, name),
  unique (id, organization_id),
  foreign key (account_id, organization_id) references public.accounts(id, organization_id)
);

create table public.document_sequences (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  sequence_key text not null,
  prefix text not null default '',
  suffix text not null default '',
  next_number bigint not null default 1 check (next_number > 0),
  padding integer not null default 4 check (padding between 1 and 12),
  updated_at timestamptz not null default now(),
  unique (organization_id, sequence_key),
  unique (id, organization_id)
);

create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  transaction_type text not null check (transaction_type in ('sale','service_sale','mixed_sale','purchase','quotation','expense','income','receipt','payment','customer_refund','supplier_refund','credit_note','debit_note','stock_adjustment','capital','drawing','journal','transfer','opening_balance')),
  document_no text,
  sequence_key text,
  transaction_date date not null default current_date,
  due_date date,
  party_id uuid,
  warehouse_id uuid,
  payment_method_id uuid,
  status text not null default 'draft' check (status in ('draft','pending_approval','approved','posted','void')),
  currency text not null check (length(currency)=3),
  subtotal numeric(18,2) not null default 0,
  discount_total numeric(18,2) not null default 0,
  tax_total numeric(18,2) not null default 0,
  round_off numeric(18,2) not null default 0,
  grand_total numeric(18,2) not null default 0,
  paid_total numeric(18,2) not null default 0,
  balance_total numeric(18,2) not null default 0,
  notes text,
  needs_review boolean not null default false,
  source text not null default 'manual',
  posted_at timestamptz,
  voided_at timestamptz,
  created_by uuid not null references auth.users(id),
  approved_by uuid references auth.users(id),
  posted_by uuid references auth.users(id),
  voided_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, document_no),
  unique (id, organization_id),
  foreign key (party_id, organization_id) references public.parties(id, organization_id),
  foreign key (warehouse_id, organization_id) references public.warehouses(id, organization_id),
  foreign key (payment_method_id, organization_id) references public.payment_methods(id, organization_id)
);

create table public.transaction_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  transaction_id uuid not null,
  line_no integer not null check (line_no > 0),
  product_id uuid,
  warehouse_id uuid,
  description text not null,
  quantity numeric(18,4) not null default 1 check (quantity > 0),
  unit_price numeric(18,4) not null default 0 check (unit_price >= 0),
  discount_amount numeric(18,2) not null default 0 check (discount_amount >= 0),
  tax_code_id uuid,
  tax_rate numeric(9,4) not null default 0 check (tax_rate between 0 and 100),
  tax_classification text not null default 'taxable' check (tax_classification in ('taxable','zero_rated','exempt','out_of_scope')),
  tax_inclusive boolean not null default false,
  input_tax_recoverable boolean,
  line_net numeric(18,2) not null default 0,
  line_tax numeric(18,2) not null default 0,
  line_total numeric(18,2) not null default 0,
  unit_cost_snapshot numeric(18,6),
  direct_cost_snapshot numeric(18,2) not null default 0,
  unique (transaction_id, line_no),
  unique (id, organization_id),
  foreign key (transaction_id, organization_id) references public.transactions(id, organization_id) on delete cascade,
  foreign key (product_id, organization_id) references public.products(id, organization_id),
  foreign key (warehouse_id, organization_id) references public.warehouses(id, organization_id),
  foreign key (tax_code_id, organization_id) references public.tax_codes(id, organization_id)
);

create table public.journals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  transaction_id uuid not null,
  journal_date date not null,
  status text not null default 'posted' check (status in ('posted','reversed')),
  reversal_of uuid,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique (transaction_id),
  unique (id, organization_id),
  foreign key (transaction_id, organization_id) references public.transactions(id, organization_id),
  foreign key (reversal_of, organization_id) references public.journals(id, organization_id)
);

create table public.journal_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  journal_id uuid not null,
  account_id uuid not null,
  party_id uuid,
  description text,
  debit numeric(18,2) not null default 0 check (debit >= 0),
  credit numeric(18,2) not null default 0 check (credit >= 0),
  created_at timestamptz not null default now(),
  foreign key (journal_id, organization_id) references public.journals(id, organization_id) on delete cascade,
  foreign key (account_id, organization_id) references public.accounts(id, organization_id),
  foreign key (party_id, organization_id) references public.parties(id, organization_id),
  check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0))
);

create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  transaction_id uuid not null,
  transaction_line_id uuid,
  product_id uuid not null,
  warehouse_id uuid not null,
  quantity_in numeric(18,4) not null default 0 check (quantity_in >= 0),
  quantity_out numeric(18,4) not null default 0 check (quantity_out >= 0),
  unit_cost numeric(18,6) not null default 0,
  reason text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key (transaction_id, organization_id) references public.transactions(id, organization_id),
  foreign key (transaction_line_id, organization_id) references public.transaction_lines(id, organization_id),
  foreign key (product_id, organization_id) references public.products(id, organization_id),
  foreign key (warehouse_id, organization_id) references public.warehouses(id, organization_id),
  check ((quantity_in > 0 and quantity_out = 0) or (quantity_out > 0 and quantity_in = 0))
);

create table public.stock_balances (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid not null,
  warehouse_id uuid not null,
  quantity numeric(18,4) not null default 0,
  average_cost numeric(18,6) not null default 0,
  updated_at timestamptz not null default now(),
  primary key (organization_id, product_id, warehouse_id),
  foreign key (product_id, organization_id) references public.products(id, organization_id),
  foreign key (warehouse_id, organization_id) references public.warehouses(id, organization_id)
);

create table public.open_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  transaction_id uuid not null,
  party_id uuid not null,
  item_type text not null check (item_type in ('receivable','payable')),
  original_amount numeric(18,2) not null check (original_amount >= 0),
  allocated_amount numeric(18,2) not null default 0 check (allocated_amount >= 0),
  due_date date,
  status text not null default 'open' check (status in ('open','partially_paid','settled','void')),
  created_at timestamptz not null default now(),
  unique (transaction_id),
  unique (id, organization_id),
  foreign key (transaction_id, organization_id) references public.transactions(id, organization_id),
  foreign key (party_id, organization_id) references public.parties(id, organization_id),
  check (allocated_amount <= original_amount)
);

create table public.allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  payment_transaction_id uuid not null,
  open_item_id uuid not null,
  amount numeric(18,2) not null check (amount > 0),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key (payment_transaction_id, organization_id) references public.transactions(id, organization_id),
  foreign key (open_item_id, organization_id) references public.open_items(id, organization_id)
);

create table public.document_profiles (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  profile_type text not null check (profile_type in ('product','service','tax','simple','cash','credit','custom')),
  version integer not null default 1 check (version > 0),
  is_active boolean not null default true,
  configuration jsonb not null default '{}'::jsonb,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique (organization_id, name, version),
  unique (id, organization_id)
);

create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  category text not null default 'general',
  storage_path text not null,
  file_name text not null,
  mime_type text not null,
  size_bytes bigint not null check (size_bytes >= 0),
  version integer not null default 1 check (version > 0),
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.voice_recordings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  transaction_id uuid,
  storage_path text not null,
  display_name text not null,
  duration_seconds numeric(12,2),
  transcript text,
  extraction jsonb,
  needs_review boolean not null default false,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key (transaction_id, organization_id) references public.transactions(id, organization_id)
);

create table public.posting_requests (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  idempotency_key text not null,
  transaction_id uuid not null,
  result jsonb,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (organization_id, idempotency_key),
  foreign key (transaction_id, organization_id) references public.transactions(id, organization_id)
);

create table public.audit_log (
  id bigint generated always as identity primary key,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  actor_id uuid references auth.users(id),
  action text not null,
  resource_type text not null,
  resource_id text,
  previous_values jsonb,
  new_values jsonb,
  created_at timestamptz not null default now()
);

create index organization_members_user_idx on public.organization_members(user_id, status, organization_id);
create index parties_org_type_idx on public.parties(organization_id, party_type, status);
create index products_org_status_idx on public.products(organization_id, status);
create index transactions_org_date_idx on public.transactions(organization_id, transaction_date desc, status);
create index transaction_lines_org_tx_idx on public.transaction_lines(organization_id, transaction_id);
create index journals_org_date_idx on public.journals(organization_id, journal_date desc);
create index journal_lines_org_account_idx on public.journal_lines(organization_id, account_id);
create index stock_movements_org_product_idx on public.stock_movements(organization_id, product_id, warehouse_id, created_at);
create index open_items_org_party_idx on public.open_items(organization_id, party_id, item_type, status, due_date);
create index allocations_org_open_item_idx on public.allocations(organization_id, open_item_id);
create index audit_log_org_time_idx on public.audit_log(organization_id, created_at desc);

create or replace function private.is_org_member(p_org uuid, p_uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.organization_members m where m.organization_id=p_org and m.user_id=p_uid and m.status='active');
$$;

create or replace function private.has_permission(p_org uuid, p_uid uuid, p_permission text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(
    select 1 from public.organization_members m
    join public.organization_role_permissions rp on rp.organization_id=m.organization_id and rp.role_id=m.role_id
    where m.organization_id=p_org and m.user_id=p_uid and m.status='active' and rp.permission_key=p_permission
  );
$$;

revoke all on schema private from public;
grant usage on schema private to authenticated;
revoke all on function private.is_org_member(uuid,uuid) from public;
revoke all on function private.has_permission(uuid,uuid,text) from public;
grant execute on function private.is_org_member(uuid,uuid), private.has_permission(uuid,uuid,text) to authenticated;

create or replace function public.create_organization(p_name text, p_currency text default 'USD')
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_org uuid; v_owner_role uuid; v_admin_role uuid; v_staff_role uuid;
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  if length(trim(p_name)) < 1 then raise exception 'organization name required'; end if;
  insert into public.organizations(name,created_by) values(trim(p_name),v_uid) returning id into v_org;
  insert into public.organization_roles(organization_id,name,is_system) values
    (v_org,'Owner',true),(v_org,'Admin',true),(v_org,'Staff',true);
  select id into v_owner_role from public.organization_roles where organization_id=v_org and name='Owner';
  select id into v_admin_role from public.organization_roles where organization_id=v_org and name='Admin';
  select id into v_staff_role from public.organization_roles where organization_id=v_org and name='Staff';
  insert into public.organization_role_permissions(organization_id,role_id,permission_key)
    select v_org,v_owner_role,key from public.permission_catalog;
  insert into public.organization_role_permissions(organization_id,role_id,permission_key)
    select v_org,v_admin_role,key from public.permission_catalog where key <> 'backup.restore';
  insert into public.organization_role_permissions(organization_id,role_id,permission_key)
    select v_org,v_staff_role,key from public.permission_catalog where key in ('organization.view','masters.view','transaction.view','transaction.create','transaction.edit','transaction.print','stock.view');
  insert into public.organization_members(organization_id,user_id,role_id,status) values(v_org,v_uid,v_owner_role,'active');
  insert into public.organization_settings(organization_id,currency,updated_by) values(v_org,upper(left(trim(p_currency),3)),v_uid);
  insert into public.accounts(organization_id,code,name,account_type,system_key) values
    (v_org,'1000','Cash','asset','cash'),(v_org,'1010','Bank','asset','bank'),(v_org,'1100','Accounts Receivable','asset','accounts_receivable'),
    (v_org,'1200','Inventory','asset','inventory'),(v_org,'1300','Input Tax','asset','input_tax'),(v_org,'2000','Accounts Payable','liability','accounts_payable'),
    (v_org,'2100','Output Tax','liability','output_tax'),(v_org,'3000','Owner Equity','equity','equity'),(v_org,'4000','Sales Revenue','income','sales_revenue'),
    (v_org,'4100','Service Revenue','income','service_revenue'),(v_org,'5000','Cost of Goods Sold','cogs','cogs'),(v_org,'6000','Operating Expense','expense','operating_expense');
  insert into public.warehouses(organization_id,code,name) values(v_org,'MAIN','Main Warehouse');
  insert into public.document_sequences(organization_id,sequence_key,prefix) values
    (v_org,'invoice','INV'),(v_org,'quotation','QT'),(v_org,'purchase','PI'),(v_org,'receipt','RV'),(v_org,'payment','PV'),(v_org,'expense','EV'),(v_org,'credit_note','CN'),(v_org,'debit_note','DN'),(v_org,'journal','JV'),(v_org,'stock_adjustment','SA');
  insert into public.audit_log(organization_id,actor_id,action,resource_type,resource_id,new_values)
    values(v_org,v_uid,'organization.created','organization',v_org::text,jsonb_build_object('name',trim(p_name)));
  return v_org;
end $$;
revoke all on function public.create_organization(text,text) from public, anon;
grant execute on function public.create_organization(text,text) to authenticated;

create or replace function private.guard_posted_transaction_update()
returns trigger language plpgsql set search_path='' as $$
begin
  if old.status in ('posted','void') and coalesce(current_setting('app.allow_posted_mutation',true),'') <> 'on' then
    raise exception 'posted or void transactions are immutable';
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger transactions_guard_posted before update on public.transactions for each row execute function private.guard_posted_transaction_update();

alter table public.organizations enable row level security;
alter table public.organization_roles enable row level security;
alter table public.organization_role_permissions enable row level security;
alter table public.organization_members enable row level security;
alter table public.organization_settings enable row level security;
alter table public.parties enable row level security;
alter table public.warehouses enable row level security;
alter table public.products enable row level security;
alter table public.tax_codes enable row level security;
alter table public.accounts enable row level security;
alter table public.payment_methods enable row level security;
alter table public.document_sequences enable row level security;
alter table public.transactions enable row level security;
alter table public.transaction_lines enable row level security;
alter table public.journals enable row level security;
alter table public.journal_lines enable row level security;
alter table public.stock_movements enable row level security;
alter table public.stock_balances enable row level security;
alter table public.open_items enable row level security;
alter table public.allocations enable row level security;
alter table public.document_profiles enable row level security;
alter table public.attachments enable row level security;
alter table public.voice_recordings enable row level security;
alter table public.posting_requests enable row level security;
alter table public.audit_log enable row level security;

create policy org_select on public.organizations for select to authenticated using (private.is_org_member(id,(select auth.uid())));
create policy org_update on public.organizations for update to authenticated using (private.has_permission(id,(select auth.uid()),'organization.admin')) with check (private.has_permission(id,(select auth.uid()),'organization.admin'));
create policy members_select on public.organization_members for select to authenticated using (private.is_org_member(organization_id,(select auth.uid())));
create policy members_write on public.organization_members for all to authenticated using (private.has_permission(organization_id,(select auth.uid()),'organization.admin')) with check (private.has_permission(organization_id,(select auth.uid()),'organization.admin'));
create policy roles_select on public.organization_roles for select to authenticated using (private.is_org_member(organization_id,(select auth.uid())));
create policy roles_write on public.organization_roles for all to authenticated using (private.has_permission(organization_id,(select auth.uid()),'organization.admin')) with check (private.has_permission(organization_id,(select auth.uid()),'organization.admin'));
create policy role_perm_select on public.organization_role_permissions for select to authenticated using (private.is_org_member(organization_id,(select auth.uid())));
create policy role_perm_write on public.organization_role_permissions for all to authenticated using (private.has_permission(organization_id,(select auth.uid()),'organization.admin')) with check (private.has_permission(organization_id,(select auth.uid()),'organization.admin'));

create policy settings_select on public.organization_settings for select to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.view'));
create policy settings_update on public.organization_settings for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));

create policy parties_select on public.parties for select to authenticated using (private.has_permission(organization_id,(select auth.uid()),'masters.view'));
create policy parties_insert on public.parties for insert to authenticated with check (private.has_permission(organization_id,(select auth.uid()),'masters.create') and created_by=(select auth.uid()));
create policy parties_update on public.parties for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'masters.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'masters.edit'));
create policy products_select on public.products for select to authenticated using (private.has_permission(organization_id,(select auth.uid()),'masters.view'));
create policy products_insert on public.products for insert to authenticated with check (private.has_permission(organization_id,(select auth.uid()),'masters.create') and created_by=(select auth.uid()));
create policy products_update on public.products for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'masters.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'masters.edit'));

create policy warehouse_select on public.warehouses for select to authenticated using (private.is_org_member(organization_id,(select auth.uid())));
create policy warehouse_write on public.warehouses for all to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
create policy tax_select on public.tax_codes for select to authenticated using (private.is_org_member(organization_id,(select auth.uid())));
create policy tax_write on public.tax_codes for all to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
create policy accounts_select on public.accounts for select to authenticated using (private.has_permission(organization_id,(select auth.uid()),'accounting.view'));
create policy accounts_write on public.accounts for all to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
create policy payment_methods_select on public.payment_methods for select to authenticated using (private.is_org_member(organization_id,(select auth.uid())));
create policy payment_methods_write on public.payment_methods for all to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));
create policy sequences_select on public.document_sequences for select to authenticated using (private.is_org_member(organization_id,(select auth.uid())));
create policy sequences_write on public.document_sequences for all to authenticated using (private.has_permission(organization_id,(select auth.uid()),'settings.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'settings.edit'));

create policy tx_select on public.transactions for select to authenticated using (private.has_permission(organization_id,(select auth.uid()),'transaction.view'));
create policy tx_insert on public.transactions for insert to authenticated with check (private.has_permission(organization_id,(select auth.uid()),'transaction.create') and created_by=(select auth.uid()) and status in ('draft','pending_approval'));
create policy tx_update on public.transactions for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'transaction.edit') and status in ('draft','pending_approval','approved')) with check (private.has_permission(organization_id,(select auth.uid()),'transaction.edit') and status in ('draft','pending_approval','approved'));
create policy lines_select on public.transaction_lines for select to authenticated using (private.has_permission(organization_id,(select auth.uid()),'transaction.view'));
create policy lines_insert on public.transaction_lines for insert to authenticated with check (private.has_permission(organization_id,(select auth.uid()),'transaction.create'));
create policy lines_update on public.transaction_lines for update to authenticated using (private.has_permission(organization_id,(select auth.uid()),'transaction.edit')) with check (private.has_permission(organization_id,(select auth.uid()),'transaction.edit'));
create policy lines_delete on public.transaction_lines for delete to authenticated using (private.has_permission(organization_id,(select auth.uid()),'transaction.edit'));

create policy journals_select on public.journals for select to authenticated using (private.has_permission(organization_id,(select auth.uid()),'accounting.view'));
create policy journal_lines_select on public.journal_lines for select to authenticated using (private.has_permission(organization_id,(select auth.uid()),'accounting.view'));
create policy stock_movements_select on public.stock_movements for select to authenticated using (private.has_permission(organization_id,(select auth.uid()),'stock.view'));
create policy stock_balances_select on public.stock_balances for select to authenticated using (private.has_permission(organization_id,(select auth.uid()),'stock.view'));
create policy open_items_select on public.open_items for select to authenticated using (private.has_permission(organization_id,(select auth.uid()),'accounting.view'));
create policy allocations_select on public.allocations for select to authenticated using (private.has_permission(organization_id,(select auth.uid()),'accounting.view'));
create policy profiles_select on public.document_profiles for select to authenticated using (private.is_org_member(organization_id,(select auth.uid())));
create policy profiles_write on public.document_profiles for all to authenticated using (private.has_permission(organization_id,(select auth.uid()),'documents.design')) with check (private.has_permission(organization_id,(select auth.uid()),'documents.design'));
create policy attachments_select on public.attachments for select to authenticated using (private.is_org_member(organization_id,(select auth.uid())));
create policy attachments_insert on public.attachments for insert to authenticated with check (private.is_org_member(organization_id,(select auth.uid())) and created_by=(select auth.uid()));
create policy voice_select on public.voice_recordings for select to authenticated using (private.is_org_member(organization_id,(select auth.uid())));
create policy voice_insert on public.voice_recordings for insert to authenticated with check (private.is_org_member(organization_id,(select auth.uid())) and created_by=(select auth.uid()));
create policy audit_select on public.audit_log for select to authenticated using (private.has_permission(organization_id,(select auth.uid()),'audit.view'));

revoke all on all tables in schema public from anon;
grant select on public.permission_catalog to authenticated;
grant select,update on public.organizations to authenticated;
grant select,insert,update,delete on public.organization_members, public.organization_roles, public.organization_role_permissions to authenticated;
grant select,update on public.organization_settings to authenticated;
grant select,insert,update on public.parties, public.products to authenticated;
grant select,insert,update,delete on public.warehouses, public.tax_codes, public.accounts, public.payment_methods, public.document_sequences, public.document_profiles to authenticated;
grant select,insert,update on public.transactions to authenticated;
grant select,insert,update,delete on public.transaction_lines to authenticated;
grant select on public.journals, public.journal_lines, public.stock_movements, public.stock_balances, public.open_items, public.allocations, public.audit_log, public.posting_requests to authenticated;
grant select,insert on public.attachments, public.voice_recordings to authenticated;
;
