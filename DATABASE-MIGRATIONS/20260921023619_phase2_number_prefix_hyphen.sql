-- 20260921023619  phase2_number_prefix_hyphen
-- Applied to Supabase project pwzpljitxamthgqllgtu

update public.document_sequences set prefix = prefix || '-'
where right(prefix,1) <> '-' and next_number = 1
  and not exists (select 1 from public.transactions t where t.organization_id=document_sequences.organization_id and t.document_no is not null);
update public.document_sequences set suffix='' where suffix is null;;
