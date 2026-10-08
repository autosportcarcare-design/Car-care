-- 20260919223353  document_designer_media_tax_foundation
-- Applied to Supabase project pwzpljitxamthgqllgtu

alter table public.organization_settings
  add column if not exists tax_registered boolean not null default false,
  add column if not exists prices_include_tax boolean not null default false,
  add column if not exists website text,
  add column if not exists logo_storage_path text;

alter table public.document_profiles
  add column if not exists active_version_id uuid,
  add column if not exists page_size text not null default 'A4' check (page_size in ('A4','A5','letter','custom')),
  add column if not exists orientation text not null default 'portrait' check (orientation in ('portrait','landscape')),
  add column if not exists custom_width_mm numeric,
  add column if not exists custom_height_mm numeric,
  add column if not exists reference_attachment_id uuid,
  add constraint document_profiles_custom_size_check check (
    page_size <> 'custom' or (custom_width_mm > 0 and custom_height_mm > 0)
  );

alter table public.document_profile_versions
  add constraint document_profile_versions_id_organization_key unique (id, organization_id);

alter table public.attachments
  add constraint attachments_id_organization_key unique (id, organization_id);

alter table public.document_profiles
  add constraint document_profiles_active_version_fk
    foreign key (active_version_id, organization_id)
    references public.document_profile_versions(id, organization_id),
  add constraint document_profiles_reference_attachment_fk
    foreign key (reference_attachment_id, organization_id)
    references public.attachments(id, organization_id);

alter table public.transactions
  add column if not exists document_profile_id uuid,
  add column if not exists document_profile_version_id uuid,
  add column if not exists organization_snapshot jsonb not null default '{}'::jsonb,
  add column if not exists party_snapshot jsonb not null default '{}'::jsonb,
  add column if not exists document_profile_snapshot jsonb not null default '{}'::jsonb;

alter table public.transactions
  add constraint transactions_document_profile_fk
    foreign key (document_profile_id, organization_id)
    references public.document_profiles(id, organization_id),
  add constraint transactions_document_profile_version_fk
    foreign key (document_profile_version_id, organization_id)
    references public.document_profile_versions(id, organization_id);

create table if not exists public.organization_settings_history (
  id bigint generated always as identity primary key,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  previous_values jsonb,
  new_values jsonb not null,
  changed_by uuid references auth.users(id),
  changed_at timestamptz not null default now()
);
create index if not exists organization_settings_history_org_time_idx on public.organization_settings_history(organization_id, changed_at desc);
alter table public.organization_settings_history enable row level security;
create policy organization_settings_history_select on public.organization_settings_history
  for select to authenticated
  using (private.is_org_member(organization_id, (select auth.uid())) and private.has_permission(organization_id, (select auth.uid()), 'settings.view'));

create or replace function private.audit_organization_settings_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old is distinct from new then
    insert into public.organization_settings_history(organization_id, previous_values, new_values, changed_by)
    values (new.organization_id, to_jsonb(old), to_jsonb(new), auth.uid());
    insert into public.audit_log(organization_id, actor_id, action, resource_type, resource_id, previous_values, new_values)
    values (new.organization_id, auth.uid(), 'settings.updated', 'organization_settings', new.organization_id::text, to_jsonb(old), to_jsonb(new));
  end if;
  return new;
end;
$$;

drop trigger if exists organization_settings_audit_trigger on public.organization_settings;
create trigger organization_settings_audit_trigger
after update on public.organization_settings
for each row execute function private.audit_organization_settings_change();

create or replace function private.capture_transaction_document_snapshots()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org jsonb;
  v_party jsonb := '{}'::jsonb;
  v_profile jsonb := '{}'::jsonb;
begin
  if new.status = 'posted' and old.status is distinct from 'posted' then
    select jsonb_build_object(
      'legal_name', s.legal_name,
      'operating_name', s.operating_name,
      'email', s.email,
      'phone', s.phone,
      'address', s.address,
      'website', s.website,
      'tax_registered', s.tax_registered,
      'tax_registration_no', s.tax_registration_no,
      'currency', s.currency,
      'tax_enabled', s.tax_enabled,
      'default_tax_rate', s.default_tax_rate,
      'prices_include_tax', s.prices_include_tax,
      'logo_storage_path', s.logo_storage_path
    ) into v_org
    from public.organization_settings s
    where s.organization_id = new.organization_id;

    if new.party_id is not null then
      select jsonb_build_object(
        'name', p.name,
        'party_type', p.party_type,
        'phone', p.phone,
        'email', p.email,
        'address', p.address,
        'tax_registration_no', p.tax_registration_no
      ) into v_party
      from public.parties p
      where p.id = new.party_id and p.organization_id = new.organization_id;
    end if;

    if new.document_profile_version_id is not null then
      select jsonb_build_object(
        'profile_id', dp.id,
        'profile_name', dp.name,
        'profile_type', dp.profile_type,
        'version_id', dpv.id,
        'version', dpv.version,
        'page_size', dp.page_size,
        'orientation', dp.orientation,
        'custom_width_mm', dp.custom_width_mm,
        'custom_height_mm', dp.custom_height_mm,
        'configuration', dpv.configuration
      ) into v_profile
      from public.document_profile_versions dpv
      join public.document_profiles dp on dp.id = dpv.document_profile_id and dp.organization_id = dpv.organization_id
      where dpv.id = new.document_profile_version_id and dpv.organization_id = new.organization_id;
    end if;

    new.organization_snapshot := coalesce(v_org, '{}'::jsonb);
    new.party_snapshot := coalesce(v_party, '{}'::jsonb);
    new.document_profile_snapshot := coalesce(v_profile, '{}'::jsonb);
  end if;
  return new;
end;
$$;

drop trigger if exists transaction_document_snapshot_trigger on public.transactions;
create trigger transaction_document_snapshot_trigger
before update of status on public.transactions
for each row execute function private.capture_transaction_document_snapshots();

create or replace function private.save_document_profile_version(
  p_profile_id uuid,
  p_configuration jsonb,
  p_change_note text default null,
  p_activate boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_version integer;
  v_id uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;

  select organization_id into v_org
  from public.document_profiles
  where id = p_profile_id
  for update;

  if v_org is null then raise exception 'Document profile not found'; end if;
  if not private.has_permission(v_org, v_uid, 'documents.design') then raise exception 'Permission denied'; end if;

  select coalesce(max(version),0)+1 into v_version
  from public.document_profile_versions
  where organization_id = v_org and document_profile_id = p_profile_id;

  insert into public.document_profile_versions(organization_id, document_profile_id, version, configuration, change_note, created_by)
  values (v_org, p_profile_id, v_version, coalesce(p_configuration,'{}'::jsonb), nullif(trim(p_change_note),''), v_uid)
  returning id into v_id;

  if p_activate then
    update public.document_profiles
    set version = v_version,
        configuration = coalesce(p_configuration,'{}'::jsonb),
        active_version_id = v_id
    where id = p_profile_id and organization_id = v_org;
  end if;

  insert into public.audit_log(organization_id, actor_id, action, resource_type, resource_id, new_values)
  values (v_org, v_uid, case when p_activate then 'document_profile.version_saved_activated' else 'document_profile.version_saved' end,
          'document_profile', p_profile_id::text,
          jsonb_build_object('version_id',v_id,'version',v_version,'change_note',p_change_note));
  return v_id;
end;
$$;

create or replace function private.activate_document_profile_version(p_version_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_profile_id uuid;
  v_version integer;
  v_configuration jsonb;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  select organization_id, document_profile_id, version, configuration
  into v_org, v_profile_id, v_version, v_configuration
  from public.document_profile_versions
  where id = p_version_id;
  if v_org is null then raise exception 'Document profile version not found'; end if;
  if not private.has_permission(v_org, v_uid, 'documents.design') then raise exception 'Permission denied'; end if;
  perform 1 from public.document_profiles where id=v_profile_id and organization_id=v_org for update;
  update public.document_profiles
  set version=v_version, configuration=v_configuration, active_version_id=p_version_id
  where id=v_profile_id and organization_id=v_org;
  insert into public.audit_log(organization_id, actor_id, action, resource_type, resource_id, new_values)
  values (v_org,v_uid,'document_profile.version_activated','document_profile',v_profile_id::text,jsonb_build_object('version_id',p_version_id,'version',v_version));
end;
$$;

create or replace function public.save_document_profile_version(p_profile_id uuid,p_configuration jsonb,p_change_note text default null,p_activate boolean default true)
returns uuid language sql security invoker set search_path=''
as $$ select private.save_document_profile_version($1,$2,$3,$4); $$;
create or replace function public.activate_document_profile_version(p_version_id uuid)
returns void language sql security invoker set search_path=''
as $$ select private.activate_document_profile_version($1); $$;
revoke all on function public.save_document_profile_version(uuid,jsonb,text,boolean) from public, anon;
revoke all on function public.activate_document_profile_version(uuid) from public, anon;
grant execute on function public.save_document_profile_version(uuid,jsonb,text,boolean) to authenticated;
grant execute on function public.activate_document_profile_version(uuid) to authenticated;

alter table public.voice_recordings
  add column if not exists mime_type text,
  add column if not exists size_bytes bigint check (size_bytes is null or size_bytes >= 0),
  add column if not exists status text not null default 'ready' check (status in ('ready','transcribing','transcribed','failed','deleted')),
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists deleted_at timestamptz;

create policy voice_update on public.voice_recordings for update to authenticated
  using (private.is_org_member(organization_id,(select auth.uid())))
  with check (private.is_org_member(organization_id,(select auth.uid())));
create policy voice_delete on public.voice_recordings for delete to authenticated
  using (private.has_permission(organization_id,(select auth.uid()),'service.manage') or private.has_permission(organization_id,(select auth.uid()),'organization.admin'));

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('business-media','business-media',false,26214400,array[
  'image/jpeg','image/png','image/webp','application/pdf','text/plain','text/csv',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'audio/webm','audio/mp4','audio/mpeg','audio/wav','audio/x-m4a'
])
on conflict (id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

create or replace function private.storage_object_org_id(p_name text)
returns uuid
language plpgsql
immutable
set search_path=''
as $$
declare v text;
begin
  v := split_part(p_name,'/',1);
  if v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then return v::uuid; end if;
  return null;
exception when others then return null;
end;
$$;

drop policy if exists business_media_select on storage.objects;
drop policy if exists business_media_insert on storage.objects;
drop policy if exists business_media_update on storage.objects;
drop policy if exists business_media_delete on storage.objects;
create policy business_media_select on storage.objects for select to authenticated
  using (bucket_id='business-media' and private.is_org_member(private.storage_object_org_id(name),(select auth.uid())));
create policy business_media_insert on storage.objects for insert to authenticated
  with check (bucket_id='business-media' and private.is_org_member(private.storage_object_org_id(name),(select auth.uid())));
create policy business_media_update on storage.objects for update to authenticated
  using (bucket_id='business-media' and private.is_org_member(private.storage_object_org_id(name),(select auth.uid())))
  with check (bucket_id='business-media' and private.is_org_member(private.storage_object_org_id(name),(select auth.uid())));
create policy business_media_delete on storage.objects for delete to authenticated
  using (bucket_id='business-media' and (
    private.has_permission(private.storage_object_org_id(name),(select auth.uid()),'service.manage') or
    private.has_permission(private.storage_object_org_id(name),(select auth.uid()),'documents.design') or
    private.has_permission(private.storage_object_org_id(name),(select auth.uid()),'organization.admin')
  ));;
