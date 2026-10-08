/* Renders a business document as A4 HTML from database records + a layout
   configuration. Used by print/PDF/share and by the document designer preview. */
(function (w) {
  var C = w.Cloud, esc = C.esc;
  var D = {};
  D.DEFAULT = {
    title: "", orientation: "portrait", accent: "#21374d", font_size: 10.5, font: "Archivo",
    logo: { show: true, size: 60, position: "left" },
    blocks: { header: true, customer: true, vehicle: true, lines: true, totals: true, words: true, notes: true, terms: true, bank: true, signature: true, photos: true, footer: true },
    columns: [["no", "#", true], ["sku", "Code", false], ["description", "Description", true], ["qty", "Qty", true], ["unit_price", "Rate", true], ["discount", "Discount", false],
      ["net", "Net", true], ["vat_rate", "VAT %", true], ["vat", "VAT", true], ["total", "Total", true]],
    photos: { columns: 3, max: 9, height: 42, caption: true, categories: ["BEFORE", "DURING", "AFTER", "DAMAGE", "INSPECTION"] },
    labels: { customer: "Bill to", vehicle: "Vehicle", signature_left: "Received by", signature_right: "For the company" },
    custom_text: "", footer_text: "", watermark: "", background: { path: "", opacity: 0.15 }
  };
  D.merge = function (cfg) {
    var d = JSON.parse(JSON.stringify(D.DEFAULT)); cfg = cfg || {};
    Object.keys(cfg).forEach(function (k) { if (cfg[k] && typeof cfg[k] === "object" && !Array.isArray(cfg[k]) && d[k] && !Array.isArray(d[k])) Object.assign(d[k], cfg[k]); else if (cfg[k] != null) d[k] = cfg[k]; });
    return d;
  };
  var TITLES = { sale: "Tax Invoice", service_sale: "Tax Invoice", mixed_sale: "Tax Invoice", quotation: "Quotation", purchase: "Purchase Invoice", purchase_order: "Purchase Order",
    receipt: "Receipt Voucher", payment: "Payment Voucher", expense: "Expense Voucher", income: "Income Voucher", credit_note: "Tax Credit Note", debit_note: "Debit Note", delivery_note: "Delivery Note",
    capital: "Capital Voucher", drawing: "Withdrawal Voucher", job_card: "Job Card" };

  /* data: {org, tx, lines, party, vehicle, job, logoUrl, bgUrl, photos:[{url,category,caption}], draft} */
  D.render = function (data, cfgIn) {
    var cfg = D.merge(cfgIn), s = data.org || {}, x = s.settings || {}, t = data.tx || {}, p = data.party || {}, v = data.vehicle, B = cfg.blocks;
    var title = cfg.title || TITLES[t.transaction_type] || "Document";
    if (!s.tax_registered && /Tax Invoice|Tax Credit/.test(title)) title = title.replace("Tax ", "");
    var cols = cfg.columns.filter(function (c) { return c[2]; });
    var money = /receipt|payment|capital|drawing/.test(t.transaction_type);
    var head = '<div class="dHead" style="border-color:' + esc(cfg.accent) + '">' +
      (cfg.logo.show && data.logoUrl ? '<img class="dLogo" src="' + esc(data.logoUrl) + '" style="height:' + Number(cfg.logo.size) + "px;order:" + (cfg.logo.position === "right" ? 2 : 0) + '" alt="' + esc(((data.company && (data.company.name || data.company.legal_name)) || "Company") + " logo") + '">' : "") +
      '<div class="dCo" style="text-align:' + (cfg.logo.position === "center" ? "center" : cfg.logo.position === "right" ? "left" : "right") + '"><b>' + esc(s.legal_name || s.operating_name || "") + "</b>" +
      (s.operating_name && s.legal_name && s.operating_name !== s.legal_name ? "<br>" + esc(s.operating_name) : "") +
      (s.address ? "<br>" + esc(s.address) : "") + (s.phone || s.email ? "<br>" + esc([s.phone, s.email].filter(Boolean).join(" · ")) : "") +
      (s.tax_registration_no ? "<br><b>TRN " + esc(s.tax_registration_no) + "</b>" : "") + (x.trade_licence ? "<br>Licence " + esc(x.trade_licence) : "") + "</div></div>";
    var meta = '<div class="dTitle"><h1 style="color:' + esc(cfg.accent) + '">' + esc(title) + (data.draft ? " — DRAFT" : "") + "</h1><table class=\"dMeta\"><tr><td>No.</td><td><b>" + esc(t.document_no || "DRAFT") + "</b></td></tr>" +
      "<tr><td>Date</td><td>" + esc(t.transaction_date || "") + "</td></tr>" + (t.due_date ? "<tr><td>Due</td><td>" + esc(t.due_date) + "</td></tr>" : "") +
      (data.job ? "<tr><td>Job card</td><td>" + esc(data.job.job_no) + "</td></tr>" : "") + "</table></div>";
    var cust = B.customer && p.id ? '<div class="dBox"><h4>' + esc(/purchase|debit|payment/.test(t.transaction_type) ? "Supplier" : cfg.labels.customer) + "</h4><b>" + esc(p.legal_name || p.display_name || p.name) + "</b>" +
      (p.address || p.address_line1 ? "<br>" + esc(p.address || p.address_line1) : "") + (p.mobile ? "<br>" + esc(p.mobile) : "") + (p.email ? "<br>" + esc(p.email) : "") +
      (p.tax_registration_no ? "<br><b>TRN " + esc(p.tax_registration_no) + "</b>" : "") + "</div>" : "";
    var veh = B.vehicle && v ? '<div class="dBox"><h4>' + esc(cfg.labels.vehicle) + "</h4><b>" + esc([v.make, v.model, v.variant, v.year].filter(Boolean).join(" ")) + "</b>" +
      (v.plate_number ? "<br>Plate " + esc(v.plate_number + (v.registration_emirate ? " (" + v.registration_emirate + ")" : "")) : "") + (v.chassis_vin ? "<br>VIN " + esc(v.chassis_vin) : "") +
      (data.job && data.job.mileage ? "<br>Mileage " + Number(data.job.mileage).toLocaleString("en-US") + " km" : v.mileage ? "<br>Mileage " + Number(v.mileage).toLocaleString("en-US") + " km" : "") + "</div>" : "";
    var lines = (data.lines || []);
    var tbl = B.lines ? '<table class="dLines"><thead><tr>' + (money ? "<th>Description</th><th class=\"n\">Amount</th>" : cols.map(function (c) { return "<th" + (/qty|price|discount|net|vat|total/.test(c[0]) ? ' class="n"' : "") + ">" + esc(c[1]) + "</th>"; }).join("")) + "</tr></thead><tbody>" +
      lines.map(function (l, i) {
        if (money) return "<tr><td>" + esc(l.description) + '</td><td class="n">' + C.money(l.line_total) + "</td></tr>";
        var cell = { no: i + 1, sku: l.sku || "", description: esc(l.description), qty: Number(l.quantity), unit_price: C.money(l.unit_price), discount: Number(l.discount_amount) ? C.money(l.discount_amount) : "",
          net: C.money(l.line_net), vat_rate: Number(l.tax_rate) + "%", vat: C.money(l.line_tax), total: C.money(l.line_total) };
        return "<tr>" + cols.map(function (c) { return "<td" + (/qty|price|discount|net|vat|total/.test(c[0]) ? ' class="n"' : "") + ">" + cell[c[0]] + "</td>"; }).join("") + "</tr>";
      }).join("") + "</tbody></table>" : "";
    var paid = Number(data.paid || 0), balance = Number(t.grand_total || 0) - paid;
    var totals = B.totals ? '<div class="dTot"><table>' + (!money ? "<tr><td>Subtotal</td><td>" + C.money(t.subtotal) + "</td></tr>" + (Number(t.discount_total) ? "<tr><td>Discount included</td><td>" + C.money(t.discount_total) + "</td></tr>" : "") +
      "<tr><td>VAT</td><td>" + C.money(t.tax_total) + "</td></tr>" : "") + (Number(t.round_off) ? "<tr><td>Round off</td><td>" + C.money(t.round_off) + "</td></tr>" : "") +
      '<tr class="g" style="background:' + esc(cfg.accent) + '"><td>Total ' + esc(t.currency || "AED") + "</td><td>" + C.money(t.grand_total) + "</td></tr>" +
      (/sale|purchase/.test(t.transaction_type) && t.document_no ? "<tr><td>Paid / applied</td><td>" + C.money(paid) + "</td></tr><tr><td><b>Balance due</b></td><td><b>" + C.money(balance) + "</b></td></tr>" : "") + "</table></div>" : "";
    var words = B.words ? '<p class="dWords"><b>Amount in words:</b> ' + esc(C.words(t.grand_total, t.currency)) + "</p>" : "";
    var photos = B.photos && (data.photos || []).length ? cfg.photos.categories.map(function (cat) {
      var ps = data.photos.filter(function (p) { return p.category === cat && p.url; }).slice(0, Number(cfg.photos.max));
      return ps.length ? '<div class="dPhotos"><h4>' + esc(cat.charAt(0) + cat.slice(1).toLowerCase()) + ' photos</h4><div style="display:grid;grid-template-columns:repeat(' + Number(cfg.photos.columns) + ',1fr);gap:4mm">' +
        ps.map(function (p) { return '<figure><img src="' + esc(p.url) + '" style="height:' + Number(cfg.photos.height) + 'mm" alt="' + esc(p.caption || ((p.category ? String(p.category).toLowerCase() + " " : "") + "vehicle photo")) + '">' + (cfg.photos.caption && p.caption ? "<figcaption>" + esc(p.caption) + "</figcaption>" : "") + "</figure>"; }).join("") + "</div></div>" : "";
    }).join("") : "";
    var notes = (B.notes && t.notes ? '<p class="dNote"><b>Notes:</b> ' + esc(t.notes) + "</p>" : "") + (cfg.custom_text ? '<p class="dNote">' + esc(cfg.custom_text) + "</p>" : "") +
      (B.terms && x.terms ? '<p class="dNote"><b>Terms:</b> ' + esc(x.terms) + "</p>" : "") + (B.terms && x.warranty && /sale/.test(t.transaction_type) ? '<p class="dNote"><b>Warranty:</b> ' + esc(x.warranty) + "</p>" : "") +
      (B.bank && x.bank_details && !/purchase|payment|debit/.test(t.transaction_type) ? '<p class="dNote"><b>Bank details:</b> ' + esc(x.bank_details) + "</p>" : "");
    var sign = B.signature ? '<div class="dSign"><div>' + esc(cfg.labels.signature_left) + "</div><div>" + esc(cfg.labels.signature_right) + "</div></div>" : "";
    var foot = B.footer && cfg.footer_text ? '<div class="dFoot">' + esc(cfg.footer_text) + "</div>" : "";
    return '<article class="doc ' + (cfg.orientation === "landscape" ? "land" : "") + '" style="font-family:' + esc(cfg.font) + ",Arial,sans-serif;font-size:" + Number(cfg.font_size) + 'pt">' +
      (data.bgUrl ? '<img class="dBg" src="' + esc(data.bgUrl) + '" style="opacity:' + Number(cfg.background.opacity) + '" alt="">' : "") +
      (cfg.watermark || data.draft || t.status === "void" ? '<div class="dMark">' + esc(t.status === "void" ? "VOID" : data.draft ? "DRAFT" : cfg.watermark) + "</div>" : "") +
      (B.header ? head : "") + meta + '<div class="dParties">' + cust + veh + "</div>" + tbl + '<div class="dEnd">' + totals + words + notes + sign + "</div>" + photos + foot + "</article>";
  };

  /* Loads everything a document needs straight from the database. */
  D.load = async function (ctx, id) {
    var sb = C.sb, q = C.q;
    var t = await q(sb.from("transactions").select("*").eq("id", id).eq("organization_id", ctx.org).maybeSingle());
    if (!t) throw new Error("Document not found in this company.");
    var r = await Promise.all([q(sb.from("transaction_lines").select("*").eq("transaction_id", id).order("line_no")),
      t.party_id ? q(sb.from("parties").select("*").eq("id", t.party_id).maybeSingle()) : null,
      t.vehicle_id ? q(sb.from("vehicles").select("*").eq("id", t.vehicle_id).maybeSingle()) : null,
      t.service_job_id ? q(sb.from("service_jobs").select("*").eq("id", t.service_job_id).maybeSingle()) : null,
      q(sb.from("organization_settings").select("*").eq("organization_id", ctx.org).single()),
      q(sb.from("open_items").select("*").eq("transaction_id", id)).catch(function () { return []; }),
      q(sb.from("products").select("id,sku").eq("organization_id", ctx.org))]);
    var data = { tx: t, lines: r[0], party: r[1], vehicle: r[2], job: r[3], org: r[4], draft: t.status === "draft", paid: r[5][0] ? r[5][0].allocated_amount : t.paid_total };
    data.lines.forEach(function (l) { var p = r[6].filter(function (x) { return x.id === l.product_id; })[0]; l.sku = p ? p.sku : ""; });
    /* posted documents use their frozen snapshots: organisation, party, layout and photos */
    if (t.status !== "draft") { if (t.organization_snapshot) data.org = Object.assign({}, data.org, t.organization_snapshot); if (t.party_snapshot) data.party = Object.assign({}, data.party, t.party_snapshot); }
    var cfg = null;
    if (t.status !== "draft" && t.document_profile_snapshot) cfg = t.document_profile_snapshot.configuration || t.document_profile_snapshot;
    if (!cfg) cfg = await D.activeConfig(ctx, t.transaction_type);
    var photoRows = t.status !== "draft" ? (t.media_snapshot || []) : await q(sb.from("transaction_media").select("attachment_id,category").eq("transaction_id", id).order("sort_order")).catch(function () { return []; });
    if (photoRows.length) {
      var att = await q(sb.from("attachments").select("id,storage_path,caption,category").in("id", photoRows.map(function (p) { return p.attachment_id; })));
      photoRows = photoRows.map(function (p) { var a = att.filter(function (x) { return x.id === p.attachment_id; })[0] || {}; return { category: p.category, caption: p.caption || a.caption, storage_path: p.storage_path || a.storage_path }; });
    }
    var paths = photoRows.map(function (p) { return p.storage_path; }).filter(Boolean);
    if (data.org.logo_storage_path) paths.push(data.org.logo_storage_path);
    var bg = cfg && cfg.background && cfg.background.path; if (bg) paths.push(bg);
    var urls = await C.signedUrls(paths, 3600).catch(function () { return {}; });
    data.photos = photoRows.map(function (p) { return { category: p.category, caption: p.caption, url: urls[p.storage_path] }; });
    data.logoUrl = urls[data.org.logo_storage_path]; data.bgUrl = bg ? urls[bg] : "";
    return { data: data, cfg: cfg };
  };
  D.PROFILE_FOR = { sale: "invoice", service_sale: "service_invoice", mixed_sale: "invoice", quotation: "quotation", purchase: "purchase_invoice", purchase_order: "purchase_order",
    receipt: "receipt_voucher", payment: "payment_voucher", expense: "expense_voucher", credit_note: "credit_note", debit_note: "debit_note", delivery_note: "delivery_note" };
  D.activeConfig = async function (ctx, type) {
    var pt = D.PROFILE_FOR[type] || "voucher";
    var p = await C.q(C.sb.from("document_profiles").select("*").eq("organization_id", ctx.org).eq("profile_type", pt).eq("is_active", true).order("created_at", { ascending: false }).limit(1)).catch(function () { return []; });
    if (!p.length) return null;
    if (p[0].active_version_id) { var v = await C.q(C.sb.from("document_profile_versions").select("configuration").eq("id", p[0].active_version_id).maybeSingle()).catch(function () { return null; }); if (v) return v.configuration; }
    return p[0].configuration;
  };
  w.DocRender = D;
})(window);
