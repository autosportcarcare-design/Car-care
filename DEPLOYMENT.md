# Deployment

## What you need
- The existing Supabase project **pwzpljitxamthgqllgtu** (do not create a new one)
- Any static web host: AppDeploy (current), Netlify, Vercel, Cloudflare Pages,
  GitHub Pages, or your own server. The app is plain HTML, CSS and JavaScript —
  there is no build step and no server code.

## 1. Database

The SQL in `DATABASE-MIGRATIONS/` is **additive**. It creates and replaces
functions, triggers and policies. It does not drop tables or delete business data.

Run the files in order in the Supabase dashboard (SQL Editor), or with the CLI:

```bash
supabase link --project-ref pwzpljitxamthgqllgtu
supabase db push
```

Order:
1. `01_phase3_reports_search_audit_status.sql`
2. `02_phase3_credit_debit_notes_po_do.sql`
3. `03_phase3_job_items_delete_policy.sql`
4. `04_phase3_restore_business_backup.sql`
5. `05_phase3_engine_fixes.sql`

Migration 5 contains fixes to existing functions and must be run last.

## 2. Storage

Bucket **business-media** must exist and stay **private**. It is already created.
Files are stored as `<company-id>/…`, and the security policy only lets members of
that company read them. Never make this bucket public.

## 3. Authentication

In Supabase → Authentication:
- Enable Email provider
- Set Site URL and Redirect URLs to your deployed address, for example
  `https://business-platform-bqegsa.appdeploy.dev` (add
  `http://localhost:8080` too if you test locally)
- **Configure custom SMTP.** The built-in Supabase mail service is rate limited
  and will reject sign-up and password-reset emails. Any SMTP provider works
  (Resend, SendGrid, Amazon SES, your own mail server). Until this is done,
  new users cannot confirm their email address.

## 4. Application

Upload the contents of this folder to your host, keeping the folder structure.
Serve over HTTPS — the camera, installable app and service worker require it.

The only key in the code is the Supabase **publishable** key in
`assets/cloud.js`. It is designed to be public and is safe in the browser: every
table is protected by row-level security, so it grants nothing on its own. There
is no service-role key, database password or secret anywhere in this package,
and there must never be one — a service-role key in the browser would bypass all
security.

`config.example.json` shows the two values if you ever point the app at a
different project.

## 5. After deploying

1. Open the site, sign in, and confirm your company loads.
2. Settings → Numbering: check the series.
3. Post one test invoice, confirm the number and the journal, then void it.
4. Backup & restore → Download backup, and keep a copy off the machine.

## Updating later

Replace the files and bump `CACHE` in `sw.js` (for example `business-platform-v4`)
so browsers and installed phone apps pick up the new version instead of the
cached one.

## Backups

- In-app: Backup & restore → Download backup (full business data as JSON).
- Supabase also keeps its own automated database backups — check the retention on
  your plan. Photos and files live in Storage and are not inside the JSON backup;
  keep a copy of the bucket if you need a complete disaster-recovery set.
