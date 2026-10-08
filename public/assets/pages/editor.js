/* Transaction editor. The browser never numbers, posts or calculates the books:
   it sends the document to PostgreSQL, which validates, numbers, posts and
   verifies inside one database transaction, then the page reads it back. */
UI.cloudPage("new", async function (ctx, view) {
  var C = Cloud, esc = C.esc, sb = C.sb;
  var TYPES = [
    ["service_sale", "Service invoice", "customer"], ["sale", "Trading invoice", "customer"], ["mixed_sale", "Tax invoice (mixed)", "customer"],
    ["quotation", "Quotation", "customer"], ["receipt", "Receipt", "customer"], ["credit_note", "Credit note", "customer"], ["delivery_note", "Delivery note", "customer"],
    ["purchase", "Purchase invoice", "supplier"], ["purchase_order", "Purchase order", "supplier"], ["payment", "Payment", "supplier"], ["debit_note", "Debit note", "supplier"],
    ["expense", "Expense", "any"], ["income", "Other income", "any"], ["capital", "Capital introduced", "none"], ["drawing", "Owner withdrawal", "none"]
  ];
  var NO_DRAFT = ["credit_note", "debit_note", "purchase_order", "delivery_note"];
  var MONEY_ONLY = ["receipt", "payment", "capital", "drawing"];
  var NEEDS_PAY = ["receipt", "payment", "expense", "income", "capital", "drawing"];
  var SALES = ["sale", "service_sale", "mixed_sale", "quotation"];
  var M = await C.masters(ctx);
  var type = C.query("type") || "service_sale", draftId = C.query("id"), jobId = C.query("job"), against = C.query("against") || C.query("copy"), isCopy = !!C.query("copy");
  var key = C.uuid(), tx = { transaction_date: C.today(), warehouse_id: (M.warehouses[0] || {}).id }, lines = [], media = [], picked = {}, vehicles = [], job = null;
  var taxOn = !!M.settings.tax_enabled, canPost = C.can("transaction.post");

  /* ---- load draft / job / original ---- */
  if (draftId) {
    var t = await C.q(sb.from("transactions").select("*").eq("id", draftId).eq("organization_id", ctx.org).maybeSingle());
    if (!t) { view.innerHTML = '<div class="panel"><div class="empty">Draft not found.</div></div>'; return; }
    if (t.status !== "draft") { location.replace("voucher-view.html?id=" + t.id); return; }
    tx = t; type = t.transaction_type;
    lines = await C.q(sb.from("transaction_lines").select("*").eq("transaction_id", t.id).order("line_no"));
  }
  if (jobId) {
    job = await C.q(sb.from("service_jobs").select("*").eq("id", jobId).eq("organization_id", ctx.org).maybeSingle());
    if (job) {
      tx.party_id = job.customer_id; tx.vehicle_id = job.vehicle_id; tx.service_job_id = job.id;
      if (!draftId) {
        var tasks = await C.q(sb.from("service_job_tasks").select("*").eq("service_job_id", job.id).neq("status", "cancelled").order("line_no"));
        var items = await C.q(sb.from("service_job_items").select("*").eq("service_job_id", job.id).order("created_at"));
        var std = M.activeTax(tx.transaction_date).filter(function (x) { return x.classification === "taxable"; })[0];
        items.forEach(function (i) { lines.push({ product_id: i.product_id, description: i.description, quantity: i.quantity, unit_price: i.unit_price, tax_code_id: std ? std.id : "", direct_cost_snapshot: i.product_id ? 0 : Number(i.unit_cost || 0) * Number(i.quantity) }); });
        tasks.forEach(function (k) { lines.push({ description: k.description + (k.category && k.category !== k.task_type ? " (" + k.category.replace(/_/g, " ") + ")" : ""), quantity: 1, unit_price: Number(k.sale_price || k.estimated_amount || 0), tax_code_id: std ? std.id : "", direct_cost_snapshot: Number(k.actual_cost || 0) }); });
      }
    }
  }
  if (against) {
    var o = await C.q(sb.from("transactions").select("*").eq("id", against).eq("organization_id", ctx.org).maybeSingle());
    if (o) { tx.party_id = o.party_id; if (!isCopy) tx.against_transaction_id = o.id; else { tx.service_job_id = o.service_job_id; tx.notes = "From " + (o.document_no || "draft"); } tx.vehicle_id = o.vehicle_id; tx.warehouse_id = o.warehouse_id || tx.warehouse_id;
      if (!lines.length) lines = (await C.q(sb.from("transaction_lines").select("*").eq("transaction_id", o.id).order("line_no"))).map(function (l) {
        return { product_id: l.product_id, description: l.description, quantity: l.quantity, unit_price: l.unit_price, discount_amount: l.discount_amount, tax_code_id: l.tax_code_id }; }); }
  }
  if (C.query("party") && !tx.party_id) tx.party_id = C.query("party");
  if (!lines.length) lines.push({ quantity: 1 });

  function tdef() { return TYPES.filter(function (x) { return x[0] === type; })[0] || TYPES[0]; }
  function partyList() {
    var k = tdef()[2];
    return M.parties.filter(function (p) { return p.status !== "archived" && (k === "any" || (k === "customer" ? p.party_type !== "supplier" : p.party_type !== "customer")); });
  }
  function prod(id) { return M.products.filter(function (p) { return p.id === id; })[0]; }
  function taxOf(id) { return M.tax.filter(function (t) { return t.id === id; })[0]; }
  function calc(l) {
    var q = Number(l.quantity) || 0, p = Number(l.unit_price) || 0, d = Number(l.discount_amount) || 0, base = Math.round((q * p - d) * 100) / 100;
    var t = taxOn && l.tax_code_id ? taxOf(l.tax_code_id) : null, r = t ? Number(t.rate) : 0, net, vat;
    if (t && t.inclusive && r > 0) { net = Math.round(base / (1 + r / 100) * 100) / 100; vat = Math.round((base - net) * 100) / 100; }
    else { net = base; vat = Math.round(net * r) / 100; }
    return { net: net, vat: vat, total: Math.round((net + vat) * 100) / 100 };
  }

  async function loadVehicles() {
    vehicles = tx.party_id ? await C.q(sb.from("vehicles").select("id,plate_number,make,model,vehicle_code").eq("organization_id", ctx.org).eq("customer_id", tx.party_id).eq("status", "active")) : [];
  }
  async function loadMedia() {
    media = []; if (!tx.service_job_id || !/sale/.test(type)) return;
    media = await C.q(sb.from("attachments").select("*").eq("organization_id", ctx.org).eq("service_job_id", tx.service_job_id).is("deleted_at", null).like("mime_type", "image/%").order("created_at"));
    var urls = await C.signedUrls(media.map(function (m) { return m.storage_path; }), 3600);
    media.forEach(function (m) { m.url = urls[m.storage_path]; });
    if (draftId) (await C.q(sb.from("transaction_media").select("attachment_id").eq("transaction_id", draftId))).forEach(function (x) { picked[x.attachment_id] = true; });
  }
  await loadVehicles(); await loadMedia();

  function opt(list, sel, blank, lab) {
    return (blank ? '<option value="">' + blank + "</option>" : "") + list.map(function (x) { return '<option value="' + x.id + '"' + (x.id === sel ? " selected" : "") + ">" + esc(lab(x)) + "</option>"; }).join("");
  }

  function draw() {
    var d = tdef(), money = MONEY_ONLY.indexOf(type) >= 0;
    var tot = lines.reduce(function (a, l) { var c = calc(l); a.net += c.net; a.vat += c.vat; a.total += c.total; return a; }, { net: 0, vat: 0, total: 0 });
    view.innerHTML = UI.head(draftId ? "Edit draft" : "New " + d[1].toLowerCase(), job ? "From job card " + esc(job.job_no) : "The server numbers and posts the document; totals below are a preview.",
      '<a class="btn" href="day-book.html">Day book</a>') +
      '<div class="pill">' + TYPES.map(function (x) { return '<a href="#" data-ty="' + x[0] + '"' + (x[0] === type ? ' class="on"' : "") + ">" + x[1] + "</a>"; }).join("") + "</div>" +
      (!taxOn ? '<div class="note">VAT is switched off for this company, so no VAT is charged. Turn it on in <a href="settings.html?tab=vat">Settings → VAT</a>.</div>' : "") +
      '<div class="panel"><div class="body form">' +
        (d[2] !== "none" ? '<label class="field span2"><span>' + (d[2] === "supplier" ? "Supplier" : d[2] === "customer" ? "Customer" : "Party") + (d[2] === "any" ? "" : " *") + '</span><select id="h_party">' +
          opt(partyList(), tx.party_id, "Choose…", function (p) { return C.partyName(p) + (p.party_code ? " · " + p.party_code : "") + (p.mobile ? " · " + p.mobile : ""); }) + "</select></label>" : "") +
        '<label class="field"><span>Date</span><input id="h_date" type="date" value="' + esc(tx.transaction_date) + '"></label>' +
        (!money && ["quotation", "purchase_order", "delivery_note"].indexOf(type) < 0 ? '<label class="field"><span>Due date</span><input id="h_due" type="date" value="' + esc(tx.due_date || "") + '"></label>' : "") +
        (!money ? '<label class="field"><span>Warehouse</span><select id="h_wh">' + opt(M.warehouses.filter(function (w) { return w.status === "active"; }), tx.warehouse_id, "—", function (w) { return w.name; }) + "</select></label>" : "") +
        (NEEDS_PAY.indexOf(type) >= 0 || ["sale", "service_sale", "mixed_sale", "purchase"].indexOf(type) >= 0 ?
          '<label class="field"><span>Payment method' + (NEEDS_PAY.indexOf(type) >= 0 ? " *" : " (blank = credit)") + '</span><select id="h_pay">' + opt(M.pay, tx.payment_method_id, NEEDS_PAY.indexOf(type) >= 0 ? "Choose…" : "Credit", function (p) { return p.name; }) + "</select></label>" : "") +
        (SALES.indexOf(type) >= 0 || type === "credit_note" || type === "delivery_note" ? '<label class="field"><span>Vehicle</span><select id="h_veh">' + opt(vehicles, tx.vehicle_id, "—", function (v) { return (v.plate_number || v.vehicle_code) + " " + [v.make, v.model].filter(Boolean).join(" "); }) + "</select></label>" : "") +
        (["credit_note", "debit_note"].indexOf(type) >= 0 ? '<label class="field span2"><span>Against original ' + (type === "credit_note" ? "invoice" : "purchase invoice") + '</span><select id="h_against"><option value="">Loading…</option></select></label>' : "") +
        '<label class="field span4"><span>Notes</span><input id="h_notes" value="' + esc(tx.notes || "") + '"></label>' +
      "</div></div>" +
      '<div class="panel" style="margin-top:12px"><h2>' + (money ? "Amount" : "Lines") + '</h2><div class="scroll"><table class="lineTbl"><thead><tr>' +
        (money ? "<th>Description</th><th class=\"n\">Amount</th><th></th>" :
          '<th>Item</th><th>Description</th><th class="n">Qty</th><th class="n">Price</th><th class="n">Discount</th>' + (taxOn ? "<th>VAT</th>" : "") +
          (type === "purchase" || type === "expense" ? "<th>Recoverable</th>" : "") + (/sale/.test(type) && C.can("profit.view") ? '<th class="n">Direct cost</th>' : "") + '<th class="n">Total</th><th></th>') +
        "</tr></thead><tbody>" + lines.map(function (l, i) {
          var c = calc(l);
          if (money) return '<tr><td class="desc"><input data-i="' + i + '" data-k="description" value="' + esc(l.description || "") + '" placeholder="e.g. Payment received"></td>' +
            '<td><input data-i="' + i + '" data-k="unit_price" type="number" step="0.01" inputmode="decimal" value="' + esc(l.unit_price == null ? "" : l.unit_price) + '"></td><td></td></tr>';
          return "<tr><td><select data-i=\"" + i + '" data-k="product_id" style="min-width:150px">' + opt(M.products.filter(function (p) { return p.status === "active"; }), l.product_id, "Free text", function (p) { return (p.sku ? p.sku + " · " : "") + p.name; }) + "</select></td>" +
            '<td class="desc"><input data-i="' + i + '" data-k="description" value="' + esc(l.description || "") + '"></td>' +
            '<td><input data-i="' + i + '" data-k="quantity" type="number" step="any" inputmode="decimal" value="' + esc(l.quantity == null ? 1 : l.quantity) + '" style="width:70px"></td>' +
            '<td><input data-i="' + i + '" data-k="unit_price" type="number" step="0.01" inputmode="decimal" value="' + esc(l.unit_price == null ? "" : l.unit_price) + '" style="width:95px"></td>' +
            '<td><input data-i="' + i + '" data-k="discount_amount" type="number" step="0.01" inputmode="decimal" value="' + esc(l.discount_amount || "") + '" style="width:80px"></td>' +
            (taxOn ? '<td><select data-i="' + i + '" data-k="tax_code_id">' + opt(M.activeTax(tx.transaction_date), l.tax_code_id, "No VAT", function (t) { return t.code + " " + t.rate + "%" + (t.inclusive ? " incl" : ""); }) + "</select></td>" : "") +
            (type === "purchase" || type === "expense" ? '<td style="text-align:center"><input type="checkbox" style="width:auto" data-i="' + i + '" data-k="input_tax_recoverable"' + (l.input_tax_recoverable === false ? "" : " checked") + "></td>" : "") +
            (/sale/.test(type) && C.can("profit.view") ? '<td><input data-i="' + i + '" data-k="direct_cost_snapshot" type="number" step="0.01" value="' + esc(l.direct_cost_snapshot || "") + '" style="width:85px" title="Labour / outside work cost for profit"></td>' : "") +
            '<td class="n" data-tot="' + i + '">' + C.money(c.total) + '</td><td><button class="btn sm" data-del="' + i + '" title="Remove line" aria-label="Remove line ' + (i + 1) + '">✕</button></td></tr>';
        }).join("") + "</tbody></table></div>" +
        (money ? "" : '<div style="padding:8px 12px"><button class="btn sm" id="addLine">+ Line</button></div>') +
        '<div class="totals" id="totBox" style="padding:0 14px 12px"><div><span>Net</span><span>' + C.money(tot.net) + "</span></div><div><span>VAT</span><span>" + C.money(tot.vat) +
        '</span></div><div class="grand"><span>Total ' + esc(M.settings.currency || "AED") + "</span><span>" + C.money(tot.total) + "</span></div></div></div>" +
      (media.length ? '<div class="panel" style="margin-top:12px"><h2>Photos on this invoice <small style="font-weight:400;color:var(--mute)">frozen into the invoice when posted</small></h2>' +
        '<div class="rowTools" style="padding:10px 14px 0">' + ["BEFORE", "DURING", "AFTER", "DAMAGE", "INSPECTION"].map(function (c) {
          return '<button class="btn sm" data-cat="' + c + '">All ' + c.toLowerCase() + "</button>"; }).join("") + '<button class="btn sm" data-cat="">None</button></div>' +
        '<div class="photoGrid">' + media.map(function (m) {
          return '<figure><label class="pick"><input type="checkbox" aria-label="Include this ' + esc(String(m.category || "").toLowerCase()) + ' photo on the invoice" data-m="' + m.id + '"' + (picked[m.id] ? " checked" : "") + "></label>" +
            (m.url ? '<img src="' + esc(m.url) + '" alt="' + esc(m.category) + '" loading="lazy">' : "") + "<figcaption>" + esc(m.category) + "</figcaption></figure>"; }).join("") + "</div></div>" : "") +
      '<div class="formFoot" style="position:sticky;bottom:0;background:var(--paper);border:0">' +
        '<button class="btn" id="cancel">Cancel</button>' +
        (NO_DRAFT.indexOf(type) < 0 ? '<button class="btn" id="draft">Save draft</button>' : "") +
        (canPost ? '<button class="btn pri" id="post">Save &amp; post</button>' : '<span style="font-size:12px;color:var(--mute)">You can save drafts. Posting needs the Post permission.</span>') +
      "</div>";
    wire();
  }

  /* read whatever is on screen right now: a tap on Save must not lose the field
     the person is still typing in */
  function syncLines() {
    view.querySelectorAll("[data-i]").forEach(function (el) {
      var l = lines[+el.dataset.i]; if (!l) return;
      l[el.dataset.k] = el.type === "checkbox" ? el.checked : el.value;
    });
  }
  /* recalculate the preview in place so nothing is lost while typing */
  function refreshTotals() {
    syncLines();
    var tot = lines.reduce(function (a, l) { var c = calc(l); a.net += c.net; a.vat += c.vat; a.total += c.total; return a; }, { net: 0, vat: 0, total: 0 });
    lines.forEach(function (l, i) { var cell = view.querySelector('[data-tot="' + i + '"]'); if (cell) cell.textContent = C.money(calc(l).total); });
    var box = document.getElementById("totBox");
    if (box) box.innerHTML = '<div><span>Net</span><span>' + C.money(tot.net) + '</span></div><div><span>VAT</span><span>' + C.money(tot.vat) +
      '</span></div><div class="grand"><span>Total ' + esc(M.settings.currency || "AED") + '</span><span>' + C.money(tot.total) + '</span></div>';
  }
  function readHeader() {
    syncLines();
    function v(id) { var e = document.getElementById(id); return e ? e.value : undefined; }
    if (v("h_party") !== undefined) tx.party_id = v("h_party") || null;
    tx.transaction_date = v("h_date") || C.today();
    if (v("h_due") !== undefined) tx.due_date = v("h_due") || null;
    if (v("h_wh") !== undefined) tx.warehouse_id = v("h_wh") || null;
    if (v("h_pay") !== undefined) tx.payment_method_id = v("h_pay") || null;
    if (v("h_veh") !== undefined) tx.vehicle_id = v("h_veh") || null;
    if (v("h_against") !== undefined) tx.against_transaction_id = v("h_against") || null;
    tx.notes = v("h_notes") || "";
  }

  function wire() {
    view.querySelectorAll("[data-ty]").forEach(function (a) { a.onclick = function (e) { e.preventDefault(); if (draftId) return C.flash("A saved draft keeps its type.", "err");
      readHeader(); type = a.dataset.ty; if (MONEY_ONLY.indexOf(type) >= 0) lines = [{ quantity: 1, description: "" }]; history.replaceState(null, "", "new-transaction.html?type=" + type + (jobId ? "&job=" + jobId : "")); loadMedia().then(draw); }; });
    view.querySelectorAll("[data-i]").forEach(function (el) {
      el.oninput = el.onchange = function () {
        var l = lines[+el.dataset.i], k = el.dataset.k;
        l[k] = el.type === "checkbox" ? el.checked : el.value;
        if (k === "product_id") {
          readHeader();                       /* read the form first … */
          var p = prod(el.value);
          if (p) {                            /* … then fill in the item's own details */
            l.description = p.name;
            l.unit_price = /purchase|debit_note|purchase_order/.test(type) ? (p.purchase_price || p.average_cost || 0) : p.sale_price;
            if (!l.tax_code_id) { var std = M.activeTax(tx.transaction_date).filter(function (x) { return x.classification === "taxable"; })[0]; if (std) l.tax_code_id = std.id; }
          }
          draw(); return;
        }
        refreshTotals();
      };
    });
    var ph = document.getElementById("h_party"); if (ph) ph.onchange = async function () { readHeader(); tx.vehicle_id = null; await loadVehicles(); draw(); };
    var hd = document.getElementById("h_date"); if (hd) hd.onchange = function () { readHeader(); draw(); };
    view.querySelectorAll("[data-del]").forEach(function (b) { b.onclick = function () { readHeader(); lines.splice(+b.dataset.del, 1); if (!lines.length) lines.push({ quantity: 1 }); draw(); }; });
    var al = document.getElementById("addLine"); if (al) al.onclick = function () { readHeader(); lines.push({ quantity: 1 }); draw(); };
    view.querySelectorAll("[data-m]").forEach(function (cb) { cb.onchange = function () { picked[cb.dataset.m] = cb.checked; }; });
    view.querySelectorAll("[data-cat]").forEach(function (b) { b.onclick = function () {
      media.forEach(function (m) { if (!b.dataset.cat) picked[m.id] = false; else if (m.category === b.dataset.cat) picked[m.id] = true; }); readHeader(); draw(); }; });
    var ag = document.getElementById("h_against");
    if (ag) {
      var types = type === "credit_note" ? ["sale", "service_sale", "mixed_sale"] : ["purchase"];
      (tx.party_id ? C.q(sb.from("transactions").select("id,document_no,transaction_date,grand_total").eq("organization_id", ctx.org).eq("party_id", tx.party_id).eq("status", "posted").in("transaction_type", types).order("transaction_date", { ascending: false }).limit(200)) : Promise.resolve([]))
        .then(function (list) { ag.innerHTML = '<option value="">— none (stays open as credit) —</option>' + list.map(function (t) {
          return '<option value="' + t.id + '"' + (t.id === tx.against_transaction_id ? " selected" : "") + ">" + esc(t.document_no) + " · " + t.transaction_date + " · " + C.money(t.grand_total) + "</option>"; }).join(""); });
    }
    document.getElementById("cancel").onclick = function () { UI.confirm("Discard changes?", "Nothing that has not been saved will be kept.", function () { history.length > 1 ? history.back() : location.replace("day-book.html"); }, "Discard"); };
    var db = document.getElementById("draft"); if (db) db.onclick = function () { save(false, db); };
    var pb = document.getElementById("post"); if (pb) pb.onclick = function () { save(true, pb); };
  }

  function payload() {
    readHeader();
    var money = MONEY_ONLY.indexOf(type) >= 0;
    var t = { transaction_type: type, transaction_date: tx.transaction_date, due_date: tx.due_date || "", party_id: tx.party_id || "", warehouse_id: tx.warehouse_id || "",
      payment_method_id: tx.payment_method_id || "", vehicle_id: tx.vehicle_id || "", service_job_id: tx.service_job_id || "", notes: tx.notes || "",
      against_transaction_id: tx.against_transaction_id || "", negative_stock_confirmed: !!tx.negative_stock_confirmed,
      company_id: tx.company_id || (M.company && M.company.id) || "" };
    if (draftId) t.id = draftId;
    var ls = lines.filter(function (l) { return (l.description || "").trim() || l.product_id || Number(l.unit_price); }).map(function (l) {
      return money ? { description: (l.description || "").trim() || C.TYPE_LABEL[type], quantity: 1, unit_price: Number(l.unit_price) || 0 } :
        { product_id: l.product_id || "", description: (l.description || "").trim(), quantity: Number(l.quantity) || 0, unit_price: Number(l.unit_price) || 0,
          discount_amount: Number(l.discount_amount) || 0, tax_code_id: taxOn ? (l.tax_code_id || "") : "", warehouse_id: tx.warehouse_id || "",
          input_tax_recoverable: l.input_tax_recoverable === false ? false : "", direct_cost_snapshot: Number(l.direct_cost_snapshot) || 0 };
    });
    return { t: t, lines: ls };
  }
  function check(p) {
    var d = tdef();
    if (d[2] === "customer" || d[2] === "supplier") { if (!p.t.party_id) return "Choose the " + d[2] + "."; }
    if (NEEDS_PAY.indexOf(type) >= 0 && !p.t.payment_method_id) return "Choose how the money was paid or received.";
    if (!p.lines.length) return "Add at least one line.";
    for (var i = 0; i < p.lines.length; i++) {
      if (!p.lines[i].description) return "Line " + (i + 1) + " needs a description.";
      if (!(p.lines[i].quantity > 0)) return "Line " + (i + 1) + " needs a quantity above zero.";
      if (MONEY_ONLY.indexOf(type) >= 0 && !(p.lines[i].unit_price > 0)) return "Enter the amount.";
    }
    return "";
  }

  async function save(post, btn) {
    var p = payload(), err = check(p);
    if (err) { C.flash(err, "err"); return; }
    C.busy(btn, true, post ? "Posting…" : "Saving…");
    try {
      if (!post) {
        var r = await C.rpc("save_transaction_draft_v2", { p_organization_id: ctx.org, p_transaction: p.t, p_lines: p.lines });
        var id = r.transaction_id || r.id || r;
        var back = await C.q(sb.from("transactions").select("id,status,grand_total").eq("id", id).maybeSingle());
        var n = await C.q(sb.from("transaction_lines").select("id", { count: "exact" }).eq("transaction_id", id));
        if (!back || back.status !== "draft" || n.length !== p.lines.length) throw new Error("The draft could not be confirmed from the database.");
        if (tx.service_job_id && media.length) {
          await C.q(sb.from("transaction_media").delete().eq("transaction_id", id));
          var rows = media.filter(function (m) { return picked[m.id]; }).map(function (m, i) { return { organization_id: ctx.org, transaction_id: id, attachment_id: m.id, category: m.category, sort_order: i }; });
          if (rows.length) await C.q(sb.from("transaction_media").insert(rows));
        }
        sessionStorage.setItem("bp.flash", "Draft saved and verified in the database.");
        location.replace("voucher-view.html?id=" + id);
        return;
      }
      var ids = media.filter(function (m) { return picked[m.id]; }).map(function (m) { return m.id; });
      var res = await C.rpc("save_and_post_any", { p_org: ctx.org, p_tx: p.t, p_lines: p.lines, p_media: ids.length ? ids : null, p_key: key });
      /* read back from PostgreSQL before saying anything */
      var chk = await C.q(sb.from("transactions").select("id,status,document_no,grand_total,media_snapshot").eq("id", res.transaction_id).maybeSingle());
      if (!chk || chk.status !== "posted" || !chk.document_no) throw new Error("The server replied, but the posted document could not be confirmed. Open the Day book before retrying.");
      if (ids.length && (!chk.media_snapshot || chk.media_snapshot.length !== ids.length)) throw new Error("Posted " + chk.document_no + ", but the photo snapshot does not match. Please report this.");
      sessionStorage.setItem("bp.flash", "Posted and verified: " + chk.document_no + (res.idempotent ? " (already posted — no duplicate created)" : ""));
      location.replace("voucher-view.html?id=" + chk.id);
    } catch (e) {
      C.busy(btn, false);
      var m = C.message(e);
      if (/negative stock requires confirmation/i.test(m)) {
        UI.confirm("Stock will go below zero", m + ". Post anyway? (needs the negative-stock override permission)", function () { tx.negative_stock_confirmed = true; save(true, btn); }, "Post anyway");
        return;
      }
      C.flash(m + " — nothing was posted.", "err");
    }
  }
  draw();
});
