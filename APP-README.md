# Business Platform

Cloud accounting, inventory and workshop management for UAE automotive businesses.
Built for AL KHAIR AL RAAZ LLC (AUTO SPORTS CAR CARE), Sharjah.

**PostgreSQL (Supabase) is the only business database.** The browser holds nothing
but the login session, the selected company and the colour theme. Numbering,
accounting, VAT, stock and posting all happen inside the database, in one
transaction, and every important save is read back and verified before the app
says it worked.

## What it does

**Money**
- Trading invoice, service invoice, tax invoice, quotation, purchase invoice,
  purchase order, delivery note, credit note, debit note, receipt, payment,
  expense, other income, capital, owner withdrawal
- SAVE DRAFT / SAVE & POST / CANCEL only — there is no approval queue
- Trading, service and tax invoices share one number series: INV-000001, INV-000002…
  Other series: QT, PI, PO, DO, RV, PV, EV, CN, DN, JC, SA, CUS, SUP, VEH
- Real double-entry accounting: chart of accounts, journals, general ledger,
  cash and bank, AR, AP, inventory, input/output VAT, sales, service revenue,
  COGS, expenses, capital, drawings. Every posted journal must balance or the
  whole posting is rolled back.
- AR/AP bill-by-bill: partial receipts and payments, one receipt across several
  invoices, advances, ageing. Over-allocation, duplicate allocation and
  cross-party allocation are refused by the database.
- UAE VAT: standard, zero-rated, exempt, out of scope; inclusive or exclusive
  prices; effective dates; recoverable and non-recoverable input VAT; VAT report.

**Stock**
- Products, materials, services, labour, outside work, packages, expense items
- SKU, barcode, pricing, weighted-average cost, minimum stock and reorder levels
- Multiple warehouses, stock ledger, counts, adjustments, damage, write-off,
  opening stock, transfers
- Negative stock policy per item or company: block, warn (needs override
  permission and confirmation) or allow

**Workshop**
- Customer → vehicle → job card → inspection → before photos → quotation → work,
  parts, labour, outside work → during photos → after photos → service invoice →
  payment → full history
- 17 task categories (ceramic, PPF, tint, paint, body repair, detailing…)
- Job statuses from open through delivered, with status history
- Service profitability per job and per invoice

**Photos and files**
- Private Supabase Storage. Camera, photo library, files, PDF, video and in-app
  voice notes, filed by category (before, during, after, damage, inspection,
  delivery, supporting)
- Photos chosen for an invoice are frozen into that invoice when it is posted.
  Photos added or deleted later never change an invoice that is already posted.

**Documents**
- Document designer with layouts and numbered versions per document type: blocks,
  columns, logo, colours, photo grids, terms, signatures, watermark, custom text,
  and an uploaded image as background reference
- A posted document keeps the exact layout version, company details and customer
  details it had at posting
- A4 print, PDF (through the browser print dialog), WhatsApp and email share

**Reports** — day book, trial balance, profit & loss, balance sheet, cash flow,
general ledger, customer and supplier ledgers, cash book, bank book, journal,
sales, purchase and expense registers, VAT summary, receivables and payables
ageing, stock summary and valuation, reorder list, invoice profit, service profit
and job register. Filters plus CSV, Excel and print/PDF export.

**Everything else** — multi-company with switching, branches, warehouses,
Owner/Admin/Manager/Accountant/Staff and custom roles with per-permission control,
Supabase row-level security isolating every company, global search (customer,
phone, WhatsApp, email, TRN, code, plate, chassis, job, invoice, SKU, date,
amount), immutable audit trail, backup and verified restore, installable PWA.

## Using it

1. Sign up, confirm your email, sign in.
2. Create your company. Defaults are UAE/AED with a standard chart of accounts.
3. Settings → VAT: create the UAE tax codes and switch VAT on when registered.
4. Settings → Company: legal name, TRN, address, logo, bank details, terms.
5. Add customers, vehicles and products, then start invoicing.

## Files

- `*.html` — one page per screen, each loading `assets/pages/<name>.js`
- `assets/cloud.js` — Supabase client, session, permissions, verified saves, uploads
- `assets/ui.js` — application shell, navigation, tables, dialogs, exports
- `assets/doc-render.js` — A4 document renderer used by print and the designer
- `assets/platform.css` — all styling, including the print stylesheet
- `DATABASE-MIGRATIONS/` — additive SQL for the database
- `sw.js`, `manifest.webmanifest` — PWA shell and install metadata

Offline: the app shell is cached so it opens without signal, but **posting,
reports and anything financial need a connection**. Nothing financial is ever
calculated or stored in the browser.
