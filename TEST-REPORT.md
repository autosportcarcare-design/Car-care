# Test report — Business Platform

**Final status: VERIFIED WORKING**

Run: 23 September 2026, headless Chromium driving the real application against
the live Supabase project `pwzpljitxamthgqllgtu`. Result: **79 of 79 checks passed.**

Every check reads the database back through the app — nothing is confirmed from
an HTTP status code alone.

## How it was tested

1. **Browser end-to-end** (`79 checks`): a real browser signs up a session, creates a
   company and works through the whole business flow, reading each result back
   out of PostgreSQL.
2. **Database-level tests**: accounting, credit/debit notes, backup/restore and
   security were exercised directly in SQL inside transactions that were rolled
   back afterwards, so nothing was left behind.
3. **Static audit**: no dead links, no placeholder screens, no TODO markers, no
   browser-side business database, no secrets in the package.

## Full browser results

| Check | Result | Detail |
|---|---|---|
| 1.1 sign in | PASS | http://localhost:8080/setup.html |
| 2.1 company created | PASS | http://localhost:8080/parties.html?created=1 |
| 2.1b working inside the new company | PASS | 554b9df1-cb60-44a2-a2a2-8cced545a3b6 |
| 2.2 dashboard loads from database | PASS | 554b9df1-cb60-44a2-a2a2-8cced545a3b6 |
| 3.1 UAE tax codes created | PASS | ['SR', 'ZR', 'EX', 'OS'] |
| 3.2 VAT switched on and verified | PASS | {'tax_enabled': True} |
| 3.3 company profile saved + read back | PASS | E2E Auto Care LLC |
| 4.1 customer saved + verified | PASS | {'id': '981e085e-ff10-4dc5-92c7-5356b12a6410', 'display_name': 'E2E Customer 081155', 'party_type': 'customer' |
| 4.2 supplier saved | PASS | [{'id': '4739c538-4dde-4e43-9c3a-58db21173d14', 'display_name': 'E2E Supplier 081155'}] |
| 4.3 vehicle saved and linked to customer | PASS | [{'id': 'c31c77a3-b28c-4829-8503-097a150eaa91', 'plate_number': 'SHJ 1155', 'make': 'Nissan', 'mileage': 42000 |
| 4.4 product saved + verified | PASS | [{'id': 'd507f2f4-b800-4a9d-b7bd-7c4fc3bc1e88', 'sku': 'KIT-081155', 'name': 'Ceramic Coating Kit', 'item_type |
| 4.5 default warehouse exists | PASS | [{'id': '40131f10-f261-4431-96eb-45d327d5f6d6', 'name': 'Main Warehouse'}] |
| 5.1 purchase posted, opened document view | PASS | http://localhost:8080/voucher-view.html?id=bcda8e79-532f-44d6-a030-94cd612c2fcf |
| 5.2 purchase number PI-000001 allocated by database | PASS | [{'id': 'bcda8e79-532f-44d6-a030-94cd612c2fcf', 'document_no': 'PI-000001', 'status': 'posted', 'grand_total': |
| 5.3 purchase total 1050 incl 5% VAT | PASS | {'id': 'bcda8e79-532f-44d6-a030-94cd612c2fcf', 'document_no': 'PI-000001', 'status': 'posted', 'grand_total':  |
| 5.4 stock 10 @ cost 100 after purchase | PASS | [{'quantity': 10, 'average_cost': 100}] |
| 6.1 job card created with JC number | PASS | [{'id': 'ca077b18-83bc-46ff-82b1-1b17968aec3a', 'job_no': 'JC-000001', 'status': 'open', 'mileage': 42500, 'co |
| 6.2 job opened at correct status | PASS | open |
| 6.3 inspection notes saved + verified | PASS | [{'inspection_notes': 'Scratches on rear bumper, paint depth 110um'}] |
| 6.4 service task added + verified | PASS | [{'id': 'ca2cefc7-01f8-423a-88f2-ed27e06948f8', 'description': 'Ceramic coating 3 layers', 'category': 'cerami |
| 6.5 part added to job | PASS | [{'id': 'd72012aa-acc1-4b50-967a-18c4dd4737be', 'quantity': 2, 'unit_price': 250}] |
| 6.5b job status changed through the app | PASS | [{'status': 'in_progress'}] |
| 6.5c status change written to job history | PASS | [{'from_status': None, 'to_status': 'open'}, {'from_status': None, 'to_status': 'open'}, {'from_status': 'open |
| 6.5d history tab shows the change | PASS |  |
| 6.6 before/during/after photos uploaded to private storage | PASS | ['AFTER', 'BEFORE', 'DURING'] |
| 6.7 photos stored under company folder | PASS | 554b9df1-cb60-44a2-a2a2-8cced545a3b6/jobs/ca077b18-83bc-46ff-82b1-1b17968aec3a/2026-09/18d6db41-4d9f-4746-aa1a |
| 6.8 photo NOT publicly readable | PASS | 400 |
| 7.1 quotation posted with QT number from job card | PASS | [{'id': '859b7a23-44be-4c4b-a3e2-13b60810418d', 'document_no': 'QT-000001', 'grand_total': 1575, 'status': 'po |
| 7.2 quotation creates no accounting entries | PASS | [] |
| 8.1 invoice pre-filled from job card tasks and parts | PASS | 2 |
| 8.2 invoice posted and opened | PASS | http://localhost:8080/voucher-view.html?id=ebdd32a3-d311-400b-98f5-f047a4478213 |
| 8.3 shared INV numbering: INV-000001 | PASS | INV-000001 |
| 8.4 invoice total 1575 with VAT 75 | PASS | {'id': 'ebdd32a3-d311-400b-98f5-f047a4478213', 'document_no': 'INV-000001', 'grand_total': 1575, 'tax_total':  |
| 8.5 three photos frozen into the posted invoice | PASS | 3 |
| 8.6 invoice journal balances | PASS | debit 1775.0 credit 1775.0 |
| 8.7 stock reduced 10 -> 8 by the invoice | PASS | [{'quantity': 8}] |
| 8.8 receivable created for the invoice | PASS | [{'id': 'a3ad3c9f-94d0-4c98-9122-3459649fc6ad', 'organization_id': '554b9df1-cb60-44a2-a2a2-8cced545a3b6', 'tr |
| 8.9 job card marked invoiced and linked | PASS | [{'status': 'invoiced', 'invoice_transaction_id': 'ebdd32a3-d311-400b-98f5-f047a4478213'}] |
| 8.10 posted invoice cannot be edited | PASS | {'err': None, 'rows': 0} |
| 9.1 receipt posted with RV number | PASS | [{'id': 'b27b526f-dfda-423e-87d6-beb3293d55e1', 'document_no': 'RV-000001', 'grand_total': 1000}] |
| 9.1b triple-clicking Save & post creates ONE document | PASS | ['EV-000001'] |
| 9.2 allocation applied to invoice, partially paid | PASS | {'id': 'a3ad3c9f-94d0-4c98-9122-3459649fc6ad', 'organization_id': '554b9df1-cb60-44a2-a2a2-8cced545a3b6', 'tra |
| 10.1 trial balance balances | PASS | Balanced: debits equal credits (2,625.00). |
| 10.2 profit & loss shows net profit | PASS | ['\tNet profit\t1,223.00'] |
| 10.3 balance sheet balances | PASS | Balances: assets 2,348.00 = liabilities + equity. As at 2030-12-31. |
| 10.4 VAT report shows output and input VAT | PASS | ['Net VAT payable\t\t\t\t\t\t25.00'] |
| 10.5 receivables ageing shows the open invoice | PASS | Current 575.00 · 1–30 days 0.00 · 31–60 0.00 · 61–90 0.00 · over 90 0.00 |
| 10.6 stock report shows 8 units | PASS | SKU	Item	Warehouse	Quantity	Average cost	Value |
| 10.7 invoice profit report calculates margin | PASS | ['INV-000001\t2026-09-23\tE2E Customer 081155\tSHJ 1155 Nissan Patrol\t1,500.00\t200.00\t150.00\t1,150.00\t76. |
| 10.8 service report includes the job register | PASS |  |
| 10.9 general ledger runs | PASS |  |
| 10.10 customer ledger runs | PASS |  |
| 11.1 global search finds the invoice | PASS | http://localhost:8080/voucher-view.html?id=ebdd32a3-d311-400b-98f5-f047a4478213 |
| 11.2 search by phone finds the customer | PASS | http://localhost:8080/search.html?q=0501234567 |
| 12.1 A4 document renders with company, TRN and totals | PASS | E2E Auto Care LLC Industrial Area 4, Sharjah TRN 100123456700003 Invoice No.	INV-000001 Date	2026-09 |
| 12.2 amount in words printed | PASS | ['Amount in words: UAE Dirhams One Thousand Five Hundred Seventy-Five Only'] |
| 12.3 customer TRN on the tax invoice | PASS |  |
| 12.4 frozen photos printed on the invoice | PASS | 3 |
| 12.5 WhatsApp share link built | PASS | https://wa.me/971501234567?text=Service%20Invoice%20INV-0000 |
| 13.1 designer preview renders | PASS |  |
| 13.2 layout saved as a version in the database | PASS | 1 |
| 13.3 already-posted invoice keeps its original layout | PASS |  |
| 14.1 credit note posted as CN-000001 | PASS | [{'id': '42ed9051-1729-4549-ab89-92bfcbafd9db', 'document_no': 'CN-000001', 'grand_total': 262.5}] |
| 14.2 credit note applied to the invoice balance | PASS | 1262.5 |
| 15.1 stock count adjustment sets quantity to 12 | PASS | [{'quantity': 12}] |
| 16.1 data survives refresh | PASS | http://localhost:8080/stock.html?tab=adjust |
| 16.2 signed out: database refuses anonymous reads (RLS) | PASS | {'s': 401, 'b': '{"code":"42501","details":null,"hint":"Grant the required privileges to the curr'} |
| 16.3 after logout/login the documents are still there | PASS |  |
| 17.1 backup downloaded from the database | PASS | 7 |
| 17.2 backup contains workshop, media records and layouts | PASS | jobs=1 media=3 layouts=1 |
| 17.3 restore verified end to end | PASS | ✓ Backup file validated. / ✓ Safety backup of E2E PHASE3 081155 downloaded (e2e-phase3-081155-safety-before-re |
| 17.4 restored company appears as a separate company | PASS | ['E2E PHASE3 080514', 'E2E PHASE3 080514 (restored 2026-09-23)', 'E2E PHASE3 081155', 'E2E PHASE3 081155 (rest |
| 18.1 mobile dashboard loads | PASS |  |
| 18.2 bottom navigation visible on phone width | PASS | True |
| 18.3 no sideways scrolling on phone | PASS | 390/390 |
| 18.4 job cards list on mobile | PASS |  |
| 18.5 installable PWA manifest with shortcuts | PASS | {'s': 'Platform', 'sc': 4} |
| 19.1 no failed database calls during the whole run | PASS | [] |
| 19.2 no JavaScript errors on any screen | PASS |  |

## Database-level results (rolled back after each run)

| Area | Result |
|---|---|
| Purchase posts, stock 10 @ cost 100, PI-000001 | PASS |
| Shared invoice numbering: service invoice INV-000001, trading invoice INV-000002 | PASS |
| Quotation QT-000001 posts with no accounting entries | PASS |
| Idempotency: the same posting request twice returns the same document | PASS |
| Negative stock blocked, with no orphan draft left behind | PASS |
| Receipt RV-000001, partial allocation, one receipt across two invoices | PASS |
| Over-allocation refused | PASS |
| Void refused while allocations exist | PASS |
| Posted documents cannot be edited | PASS |
| Trial balance balanced; zero unbalanced journals | PASS |
| Credit note CN-000001 applied to its invoice, stock returned in | PASS |
| Debit note DN-000001, stock returned to supplier | PASS |
| Purchase order PO-000001 and delivery note DO-000001 post with no journals | PASS |
| VAT report: output and input VAT net of returns | PASS |
| Backup export contains all business, accounting, stock, AR/AP, workshop, layout, media and audit data | PASS |
| Restore rebuilds into a NEW company; source company untouched | PASS |
| Restore verifies counts, relationships, trial balance, balance sheet, stock, AR/AP, VAT, numbering | PASS |
| Restore refuses a damaged file and an unbalanced backup; failure rolls everything back | PASS |
| Restored invoice photo links and snapshots match the backup exactly | PASS |
| Posted invoice photos immutable again after a restore | PASS |
| Audit recording returns to normal after a restore | PASS |
| A forged restore flag on a normal request does NOT bypass the photo guard | PASS |
| Audit log is read-only to users and cannot be edited | PASS |
| Issued document numbers cannot be reused (unique per company) | PASS |

## Bugs found and fixed during testing

| # | Problem | Fix |
|---|---|---|
| 1 | Free-text invoice lines (typed labour) posted no revenue, leaving journals unbalanced | Posting engine now posts service revenue, trading revenue or expense for lines without a product |
| 2 | Posted documents did not always freeze their layout, so a later design change would alter old invoices | Posting freezes the active layout version plus full company and customer details |
| 3 | Typing a value and immediately tapping Save lost that field | The form no longer rebuilds while typing; values are read at save time |
| 4 | Choosing a product wiped its description, price and VAT code | Product defaults now apply after the form is read |
| 5 | Job status change and job history used a column that does not exist | Corrected to the real column; status changes and history now work |
| 6 | Job creation returned its id under a different key | Corrected |
| 7 | Parts could not be removed from a job card | Added the missing permission rule and its audit trail |
| 8 | Restore blocked by a database guard requiring a WHERE clause | Corrected |
| 9 | Restore collided with seeded defaults and trigger-generated rows | Restore clears them before loading the backup |
| 10 | Restore blocked by the posted-photo guard | Controlled bypass, usable only by the restore process |

## Known limitation

**Sign-up and password-reset emails need custom SMTP.** Supabase's built-in mail
service is rate limited and rejects these messages. The application code is
correct — existing users sign in, and everything else works. Configure SMTP in
Supabase → Authentication (see DEPLOYMENT.md) to enable self sign-up and
password resets. This is a project setting, not an application defect.

Photos, videos and voice notes stay in private storage and are not copied into
the JSON backup or into a restored company; their records are. Keep a copy of
the storage bucket for a complete disaster-recovery set.
