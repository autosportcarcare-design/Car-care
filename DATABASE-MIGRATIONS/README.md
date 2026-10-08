# Database migrations

Every file here was exported from the live Supabase project
`pwzpljitxamthgqllgtu` on 23 September 2026. Together they are the complete,
ordered migration history, so applying them in filename order reproduces the
deployed schema on a clean, compatible Supabase/PostgreSQL database.

All of it is **additive**: it creates or replaces tables, functions, triggers
and policies. Nothing drops a table or deletes business data.

## Applying

Already applied to `pwzpljitxamthgqllgtu` — redeploying the web app needs no
database work at all.

For a **new** project:

```bash
supabase link --project-ref YOUR-NEW-PROJECT-REF
cp *.sql supabase/migrations/
supabase db push
```

Or paste each file, in filename order, into the SQL Editor.

Afterwards, create the private storage bucket `business-media` and apply the
storage policies (they are inside `…_service_document_backup_foundation.sql`
and `…_allow_private_workshop_video_media.sql`).

## What the phase 3 files add

| File | Contents |
|------|----------|
| `…_phase3_master_vehicle_service_media` and earlier | Multi-company foundation, atomic posting engine, document designer, workshop and backup foundations |
| `20260922162234_phase3_reports_search_audit_status` | Report functions (account balances, ledger, VAT, open items, invoice profit, stock, dashboard), global search, job status/update functions, attachment deletion that refuses photos on posted invoices, audit triggers on master tables, audit log made non-editable |
| `20260922162522_phase3_credit_debit_notes_po_do` | Atomic posting for credit notes, debit notes, purchase orders and delivery notes — VAT reversal, stock return, automatic offset against the original invoice — plus the single `save_and_post_any` entry point |
| `20260922163635_phase3_job_items_delete_policy` | Permission to remove a part from a job card, with its audit trail |
| `20260922221715_phase3_restore_business_backup` | Verified restore into a new company |
| `20260923075627_phase3_restore_bypass_hardening` | Restricts the restore bypass to the controlled restore process only |
| `20260923080000_phase3_engine_live_state` | Final state of the posting engine and restore functions, including the free-text line fix and the layout/customer snapshot capture |

The last file replaces functions defined earlier in the history, so keep it last.

## Security note

The restore process may momentarily set a transaction-local flag that lets it
rebuild posted documents exactly as they were. That path requires both the flag
**and** the temporary id-map table that only `restore_business_backup` creates,
so an ordinary API request can never reach it. Outside a restore, posted
documents, their photo snapshots and the audit log stay immutable.
