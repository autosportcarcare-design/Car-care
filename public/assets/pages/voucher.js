UI.cloudPage("records", async function (ctx, view) {
  var C = Cloud, sb = C.sb, esc = C.esc, id = C.query("id");
  var flash = sessionStorage.getItem("bp.flash"); if (flash) { sessionStorage.removeItem("bp.flash"); setTimeout(function () { C.flash(flash); }, 50); }
  var t = await C.q(sb.from("transactions").select("*").eq("id", id).eq("organization_id", ctx.org).maybeSingle());
  if (!t) { view.innerHTML = '<div class="panel"><div class="empty">Document not found in this company.</div></div>'; return; }
  var res = await Promise.all([
    C.q(sb.from("transaction_lines").select("*").eq("transaction_id", id).order("line_no")),
    t.party_id ? C.q(sb.from("parties").select("*").eq("id", t.party_id).maybeSingle()) : null,
    t.vehicle_id ? C.q(sb.from("vehicles").select("*").eq("id", t.vehicle_id).maybeSingle()) : null,
    C.q(sb.from("accounts").select("id,code,name").eq("organization_id", ctx.org)),
    C.q(sb.from("journals").select("id,journal_date,status,reversal_of").eq("transaction_id", id)).catch(function () { return []; }),
    C.q(sb.from("stock_movements").select("*").eq("transaction_id", id)).catch(function () { return []; }),
    C.q(sb.from("open_items").select("*").eq("transaction_id", id)).catch(function () { return []; }),
    C.q(sb.from("allocations").select("*").eq("payment_transaction_id", id)).catch(function () { return []; }),
    C.q(sb.from("products").select("id,name,sku").eq("organization_id", ctx.org)),
    C.q(sb.from("transaction_media").select("*").eq("transaction_id", id).order("sort_order")).catch(function () { return []; }),
    C.q(sb.from("payment_methods").select("id,name").eq("organization_id", ctx.org))
  ]);
  var lines = res[0], party = res[1], veh = res[2], accts = res[3], journals = res[4], moves = res[5], open = res[6], allocOut = res[7], prods = res[8], tmedia = res[9], pays = res[10];
  var jl = journals.length ? await C.q(sb.from("journal_lines").select("*").in("journal_id", journals.map(function (j) { return j.id; }))) : [];
  var allocIn = open.length ? await C.q(sb.from("allocations").select("*").in("open_item_id", open.map(function (o) { return o.id; }))) : [];
  var linkIds = allocIn.map(function (a) { return a.payment_transaction_id; }).concat(allocOut.map(function (a) { return a.open_item_id; }));
  var linked = {}, openById = {};
  if (allocOut.length) (await C.q(sb.from("open_items").select("id,transaction_id").in("id", allocOut.map(function (a) { return a.open_item_id; })))).forEach(function (o) { openById[o.id] = o.transaction_id; });
  var tids = allocIn.map(function (a) { return a.payment_transaction_id; }).concat(Object.values(openById));
  if (tids.length) (await C.q(sb.from("transactions").select("id,document_no,transaction_type,transaction_date").in("id", tids))).forEach(function (x) { linked[x.id] = x; });
  function acc(i) { var a = accts.filter(function (x) { return x.id === i; })[0]; return a ? a.code + " " + a.name : i; }
  function pr(i) { var p = prods.filter(function (x) { return x.id === i; })[0]; return p ? p.name : "—"; }
  var label = C.TYPE_LABEL[t.transaction_type] || t.transaction_type, posted = t.status === "posted", isInv = /sale/.test(t.transaction_type);
  var snap = t.media_snapshot || [];
  var photoRows = posted ? snap : tmedia.map(function (m) { return { attachment_id: m.attachment_id, category: m.category }; });
  var photoPaths = [];
  if (photoRows.length) {
    var att = await C.q(sb.from("attachments").select("id,storage_path,category").in("id", photoRows.map(function (p) { return p.attachment_id; })));
    photoRows.forEach(function (p) { var a = att.filter(function (x) { return x.id === p.attachment_id; })[0]; p.storage_path = p.storage_path || (a && a.storage_path); if (p.storage_path) photoPaths.push(p.storage_path); });
  }
  var urls = await C.signedUrls(photoPaths, 3600).catch(function () { return {}; });

  var jd = jl.reduce(function (a, l) { a.d += Number(l.debit); a.c += Number(l.credit); return a; }, { d: 0, c: 0 });
  var tools = '<a class="btn" href="day-book.html">Day book</a> ' +
    (t.status === "draft" ? '<a class="btn" href="new-transaction.html?id=' + t.id + (t.service_job_id ? "&job=" + t.service_job_id : "") + '">Edit draft</a> ' + (C.can("transaction.post") ? '<button class="btn pri" id="postDraft">Save &amp; post</button> ' : "") : "") +
    (posted ? '<a class="btn pri" href="print-preview.html?id=' + t.id + '">Print / PDF / Share</a> ' : '<a class="btn" href="print-preview.html?id=' + t.id + '">Preview</a> ') +
    (posted && isInv && C.can("transaction.create") ? '<a class="btn" href="new-transaction.html?type=credit_note&against=' + t.id + '">Credit note</a> <a class="btn" href="new-transaction.html?type=receipt&party=' + t.party_id + '">Receive payment</a> ' : "") +
    (posted && t.transaction_type === "purchase" ? '<a class="btn" href="new-transaction.html?type=debit_note&against=' + t.id + '">Debit note</a> ' : "") +
    (posted && ["quotation", "delivery_note"].indexOf(t.transaction_type) >= 0 ? '<a class="btn" href="new-transaction.html?type=service_sale&copy=' + t.id + '">Convert to invoice</a> ' : "") +
    (posted && t.transaction_type === "purchase_order" ? '<a class="btn" href="new-transaction.html?type=purchase&copy=' + t.id + '">Convert to purchase</a> ' : "") +
    (posted && ["receipt", "payment"].indexOf(t.transaction_type) >= 0 && C.can("transaction.post") ? '<button class="btn" id="alloc">Allocate</button> ' : "") +
    (posted && C.can("transaction.void") ? '<button class="btn warn" id="void">Void</button>' : "");

  view.innerHTML = UI.head((t.document_no || "Draft") + " · " + label, UI.tag(t.status) + " " + t.transaction_date + (party ? " · " + esc(C.partyName(party)) : "") + (t.posted_at ? " · posted " + C.when(t.posted_at) : ""), tools) +
    '<div class="kpis">' + UI.stat("Total", C.money(t.grand_total), esc(t.currency)) + UI.stat("VAT", C.money(t.tax_total)) +
      UI.stat(isInv || t.transaction_type === "purchase" ? "Paid / applied" : "Net", C.money(isInv || t.transaction_type === "purchase" ? (open[0] ? open[0].allocated_amount : t.paid_total) : t.subtotal)) +
      UI.stat("Outstanding", C.money(open[0] ? open[0].original_amount - open[0].allocated_amount : 0), open[0] ? open[0].status.replace(/_/g, " ") : "", open[0] && open[0].status !== "settled") + "</div>" +
    '<div class="panel"><h2>Details</h2>' + UI.kv([["Party", party ? C.partyName(party) + (party.tax_registration_no ? " · TRN " + party.tax_registration_no : "") : "—"],
      ["Vehicle", veh ? [veh.plate_number, veh.make, veh.model].filter(Boolean).join(" ") : ""], ["Due date", t.due_date],
      ["Payment", t.payment_method_id ? (pays.filter(function (p) { return p.id === t.payment_method_id; })[0] || {}).name : (isInv || t.transaction_type === "purchase" ? "Credit" : "")],
      ["Job card", t.service_job_id ? '<a href="job-cards.html?id=' + t.service_job_id + '">Open job</a>' : "", true], ["Notes", t.notes]]) + "</div>" +
    '<h3 class="formSec">Lines</h3>' + UI.table(["Item", "Description", "Qty", "Price", "Discount", "VAT %", "Net", "VAT", "Total"], lines.map(function (l) {
      return "<tr><td>" + esc(l.product_id ? pr(l.product_id) : "—") + "</td><td>" + esc(l.description) + '</td><td class="n">' + Number(l.quantity) + '</td><td class="n">' + C.money(l.unit_price) +
        '</td><td class="n">' + C.money(l.discount_amount) + '</td><td class="n">' + Number(l.tax_rate) + '</td><td class="n">' + C.money(l.line_net) + '</td><td class="n">' + C.money(l.line_tax) + '</td><td class="n">' + C.money(l.line_total) + "</td></tr>";
    }), "No lines.") +
    (jl.length ? '<h3 class="formSec">Journal ' + (Math.abs(jd.d - jd.c) < 0.005 ? '<span class="verified">balanced ' + C.money(jd.d) + "</span>" : '<span class="due">UNBALANCED</span>') + "</h3>" +
      UI.table(["Account", "Description", "Debit", "Credit"], jl.map(function (l) { return "<tr><td>" + esc(acc(l.account_id)) + "</td><td>" + esc(l.description || "") + '</td><td class="n">' + (Number(l.debit) ? C.money(l.debit) : "") + '</td><td class="n">' + (Number(l.credit) ? C.money(l.credit) : "") + "</td></tr>"; })) : "") +
    (moves.length ? '<h3 class="formSec">Stock movements</h3>' + UI.table(["Item", "In", "Out", "Unit cost", "Reason"], moves.map(function (m) {
      return "<tr><td>" + esc(pr(m.product_id)) + '</td><td class="n">' + (Number(m.quantity_in) || "") + '</td><td class="n">' + (Number(m.quantity_out) || "") + '</td><td class="n">' + C.money(m.unit_cost) + "</td><td>" + esc(m.reason || "") + "</td></tr>"; })) : "") +
    (allocIn.length || allocOut.length ? '<h3 class="formSec">Allocations</h3>' + UI.table(["Document", "Date", "Amount"], allocIn.map(function (a) {
      var x = linked[a.payment_transaction_id] || {}; return '<tr><td><a href="voucher-view.html?id=' + a.payment_transaction_id + '">' + esc(x.document_no || "") + "</a> " + esc(C.TYPE_LABEL[x.transaction_type] || "") + "</td><td>" + C.date(a.created_at) + '</td><td class="n">' + C.money(a.amount) + "</td></tr>"; })
      .concat(allocOut.map(function (a) { var x = linked[openById[a.open_item_id]] || {}; return '<tr><td>Applied to <a href="voucher-view.html?id=' + x.id + '">' + esc(x.document_no || "") + "</a></td><td>" + C.date(a.created_at) + '</td><td class="n">' + C.money(a.amount) + "</td></tr>"; }))) : "") +
    (photoRows.length ? '<h3 class="formSec">Photos ' + (posted ? "(frozen at posting)" : "(selected for this draft)") + '</h3><div class="panel"><div class="photoGrid">' + photoRows.map(function (p) {
      return "<figure>" + (urls[p.storage_path] ? '<img src="' + esc(urls[p.storage_path]) + '" alt="' + esc(String(p.category || "").toLowerCase() + " photo") + '">' : "") + "<figcaption>" + esc(p.category) + "</figcaption></figure>"; }).join("") + "</div></div>" : "") +
    '<h3 class="formSec">History</h3><div id="hist" class="panel"><div class="empty">Loading…</div></div>';

  C.q(sb.from("audit_log").select("action,created_at,new_values").eq("organization_id", ctx.org).eq("resource_type", "transaction").eq("resource_id", id).order("created_at")).then(function (h) {
    document.getElementById("hist").innerHTML = h.length ? h.map(function (e) { return '<div class="hist"><b>' + esc(e.action.replace("transaction.", "")) + "</b> <em>" + C.when(e.created_at) + "</em></div>"; }).join("") : '<div class="empty">No history visible (needs the audit permission).</div>';
  }).catch(function () { document.getElementById("hist").innerHTML = '<div class="empty">History needs the audit permission.</div>'; });

  var pd = document.getElementById("postDraft");
  if (pd) pd.onclick = async function () {
    C.busy(pd, true, "Posting…");
    try {
      var key = sessionStorage.getItem("bp.key." + id) || C.uuid(); sessionStorage.setItem("bp.key." + id, key);
      var tm = tmedia.map(function (m) { return m.attachment_id; });
      var r = await C.rpc("save_and_post_any", { p_org: ctx.org, p_tx: { id: id, transaction_type: t.transaction_type, transaction_date: t.transaction_date, due_date: t.due_date || "", party_id: t.party_id || "",
        warehouse_id: t.warehouse_id || "", payment_method_id: t.payment_method_id || "", vehicle_id: t.vehicle_id || "", service_job_id: t.service_job_id || "", notes: t.notes || "", company_id: t.company_id },
        p_lines: lines.map(function (l) { return { product_id: l.product_id || "", description: l.description, quantity: l.quantity, unit_price: l.unit_price, discount_amount: l.discount_amount, tax_code_id: l.tax_code_id || "",
          warehouse_id: l.warehouse_id || "", input_tax_recoverable: l.input_tax_recoverable == null ? "" : l.input_tax_recoverable, direct_cost_snapshot: l.direct_cost_snapshot || 0 }; }),
        p_media: tm.length ? tm : null, p_key: key });
      var chk = await C.q(sb.from("transactions").select("status,document_no").eq("id", r.transaction_id).single());
      if (chk.status !== "posted") throw new Error("Posting could not be confirmed.");
      sessionStorage.removeItem("bp.key." + id); sessionStorage.setItem("bp.flash", "Posted and verified: " + chk.document_no); location.reload();
    } catch (e) { C.busy(pd, false); C.flash(C.message(e) + " — nothing was posted.", "err"); }
  };
  var vb = document.getElementById("void");
  if (vb) vb.onclick = function () {
    UI.confirm("Void " + t.document_no + "?", "A reversing journal and stock movement are posted. The number stays used and the original remains visible. This cannot be undone.", async function () {
      try { await C.rpc("void_transaction", { p_transaction_id: id, p_idempotency_key: "void-" + id });
        var chk = await C.q(sb.from("transactions").select("status").eq("id", id).single());
        if (chk.status !== "void") throw new Error("The void could not be confirmed.");
        sessionStorage.setItem("bp.flash", "Voided and verified."); location.reload();
      } catch (e) { C.flash(C.message(e), "err"); }
    }, "Void");
  };
  var ab = document.getElementById("alloc");
  if (ab) ab.onclick = async function () {
    var kind = t.transaction_type === "receipt" ? "receivable" : "payable";
    var items = await C.rpc("rpt_open_items", { p_org: ctx.org, p_kind: kind, p_party: t.party_id }).catch(function (e) { C.flash(C.message(e), "err"); return []; });
    var used = allocOut.reduce(function (a, x) { return a + Number(x.amount); }, 0), left = Math.round((Number(t.grand_total) - used) * 100) / 100;
    UI.dialog({ title: "Allocate " + t.document_no, wide: true, okLabel: "Allocate", keepOpen: true,
      html: '<p style="font-size:13px">Unallocated: <b>' + C.money(left) + "</b>. Enter amounts against each " + (kind === "receivable" ? "invoice" : "bill") + ".</p>" +
        (items.length ? '<table><thead><tr><th>Document</th><th>Date</th><th class="n">Outstanding</th><th class="n">Allocate</th></tr></thead><tbody>' + items.map(function (o) {
          return "<tr><td>" + esc(o.document_no) + "</td><td>" + o.doc_date + '</td><td class="n">' + C.money(o.outstanding) + '</td><td><input type="number" step="0.01" data-oi="' + o.open_item_id + '" data-max="' + o.outstanding + '" style="width:110px"></td></tr>'; }).join("") + "</tbody></table>"
          : '<div class="empty">Nothing outstanding for this party.</div>'),
      onOk: async function (wrap, close) {
        var ins = Array.prototype.slice.call(wrap.querySelectorAll("[data-oi]")).filter(function (i) { return Number(i.value) > 0; });
        var sum = ins.reduce(function (a, i) { return a + Number(i.value); }, 0);
        if (!ins.length) return C.flash("Enter at least one amount.", "err");
        if (sum - left > 0.005) return C.flash("That is more than the unallocated " + C.money(left) + ".", "err");
        try {
          for (var i = 0; i < ins.length; i++) {
            if (Number(ins[i].value) - Number(ins[i].dataset.max) > 0.005) throw new Error("An amount is more than that document's outstanding balance.");
            await C.rpc("allocate_open_item", { p_payment_transaction_id: id, p_open_item_id: ins[i].dataset.oi, p_amount: Number(ins[i].value) });
          }
          var after = await C.q(sb.from("allocations").select("amount").eq("payment_transaction_id", id));
          if (Math.abs(after.reduce(function (a, x) { return a + Number(x.amount); }, 0) - (used + sum)) > 0.005) throw new Error("Allocation could not be confirmed.");
          close(); sessionStorage.setItem("bp.flash", "Allocated and verified: " + C.money(sum)); location.reload();
        } catch (e) { C.flash(C.message(e), "err"); }
      } });
  };
});
