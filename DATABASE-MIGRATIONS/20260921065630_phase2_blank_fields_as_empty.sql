-- 20260921065630  phase2_blank_fields_as_empty
-- Applied to Supabase project pwzpljitxamthgqllgtu


create or replace function private.strip_blank(p jsonb) returns jsonb language sql immutable set search_path='' as $$
  select coalesce(jsonb_object_agg(key, case when jsonb_typeof(value)='string' then to_jsonb(trim(value #>> '{}')) else value end), '{}'::jsonb)
  from jsonb_each(coalesce(p,'{}'::jsonb))
  where value <> 'null'::jsonb and not (jsonb_typeof(value)='string' and trim(value #>> '{}') = '');
$$;

alter function private.save_party(uuid,uuid,jsonb) rename to save_party_core;
alter function private.save_vehicle(uuid,uuid,jsonb) rename to save_vehicle_core;

create or replace function private.save_party(p_org uuid, p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v jsonb := private.strip_blank(p_data); k text;
begin
  foreach k in array array['credit_limit','credit_days','opening_balance'] loop
    if v ? k and (v->>k) !~ '^-?[0-9]+(\.[0-9]+)?$' then raise exception '% must be a number', replace(k,'_',' '); end if;
  end loop;
  return private.save_party_core(p_org,p_id,v);
end $$;

create or replace function private.save_vehicle(p_org uuid, p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v jsonb := private.strip_blank(p_data);
begin
  if v ? 'mileage' and (v->>'mileage') !~ '^[0-9]+(\.[0-9]+)?$' then raise exception 'mileage must be a number'; end if;
  if v ? 'registration_expiry' and (v->>'registration_expiry') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'registration expiry must be a date'; end if;
  if v ? 'insurance_expiry' and (v->>'insurance_expiry') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'insurance expiry must be a date'; end if;
  return private.save_vehicle_core(p_org,p_id,v);
end $$;
;
