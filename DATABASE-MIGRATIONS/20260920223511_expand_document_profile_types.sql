-- 20260920223511  expand_document_profile_types
-- Applied to Supabase project pwzpljitxamthgqllgtu

alter table public.document_profiles drop constraint if exists document_profiles_profile_type_check;
alter table public.document_profiles add constraint document_profiles_profile_type_check check (profile_type = any (array[
  'product','service','tax','simple','cash','credit','custom',
  'invoice','service_invoice','quotation','service_quotation','voucher','receipt_voucher','payment_voucher','expense_voucher','credit_note','debit_note','delivery_note','purchase_invoice','purchase_order','job_card','inspection','before_service','after_service'
]));;
