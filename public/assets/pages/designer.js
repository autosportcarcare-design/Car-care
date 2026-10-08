UI.cloudPage("designer", async function (ctx, view) {
  var C = Cloud, sb = C.sb, esc = C.esc;
  var TYPES = [["service_invoice", "Service invoice", "service_sale"], ["invoice", "Trading / tax invoice", "sale"], ["quotation", "Quotation", "quotation"], ["receipt_voucher", "Receipt voucher", "receipt"],
    ["payment_voucher", "Payment voucher", "payment"], ["expense_voucher", "Expense voucher", "expense"], ["credit_note", "Credit note", "credit_note"], ["debit_note", "Debit note", "debit_note"],
    ["delivery_note", "Delivery note", "delivery_note"], ["purchase_invoice", "Purchase invoice", "purchase"], ["purchase_order", "Purchase order", "purchase_order"]];
  var PRESETS = { classic: {}, modern: { accent: "#0f766e", font: "Archivo", logo: { position: "right" } }, compact: { font_size: 9, photos: { columns: 4, height: 30 }, blocks: { vehicle: true, signature: false } },
    workshop: { accent: "#7c2d12", photos: { columns: 3, max: 9, height: 45 }, labels: { signature_left: "Customer signature (vehicle received)" } } };
  var ptype = C.query("type") || "service_invoice", canEdit = C.can("documents.design");
  var t3 = TYPES.filter(function (x) { return x[0] === ptype; })[0] || TYPES[0];
  var profiles = await C.q(sb.from("document_profiles").select("*").eq("organization_id", ctx.org).eq("profile_type", ptype).order("created_at"));
  var prof = profiles.filter(function (p) { return p.id === C.query("profile"); })[0] || profiles.filter(function (p) { return p.is_active; })[0] || profiles[0];
  var versions = prof ? await C.q(sb.from("document_profile_versions").select("*").eq("document_profile_id", prof.id).order("version", { ascending: false })) : [];
  var active = prof && versions.filter(function (v) { return v.id === prof.active_version_id; })[0];
  var cfg = DocRender.merge(active ? active.configuration : prof ? prof.configuration : {});
  /* preview with the latest real document of this type, or sample data */
  var sample = await C.q(sb.from("transactions").select("id").eq("organization_id", ctx.org).eq("transaction_type", t3[2]).eq("status", "posted").order("created_at", { ascending: false }).limit(1)).catch(function () { return []; });
  var data;
  if (sample.length) { data = (await DocRender.load(ctx, sample[0].id)).data; data.draft = false; }
  else { var org = await C.q(sb.from("organization_settings").select("*").eq("organization_id", ctx.org).single());
    var lg = org.logo_storage_path ? (await C.signedUrls([org.logo_storage_path]))[org.logo_storage_path] : "";
    data = { org: org, logoUrl: lg, tx: { transaction_type: t3[2], document_no: "SAMPLE-000001", transaction_date: C.today(), due_date: C.today(), subtotal: 1500, tax_total: 75, grand_total: 1575, currency: org.currency || "AED", notes: "Sample preview", status: "posted" },
      party: { id: "x", display_name: "Sample Customer LLC", address: "Industrial Area 4, Sharjah", mobile: "+971 50 000 0000", tax_registration_no: "100000000000003" },
      vehicle: /sale|quotation|credit/.test(t3[2]) ? { make: "Nissan", model: "Patrol", year: 2024, plate_number: "SHJ 1 12345", chassis_vin: "JN1TANY62U0000000" } : null,
      lines: [{ description: "Ceramic coating — 3 layers", quantity: 1, unit_price: 1200, line_net: 1200, tax_rate: 5, line_tax: 60, line_total: 1260 }, { description: "Interior detailing", quantity: 1, unit_price: 300, line_net: 300, tax_rate: 5, line_tax: 15, line_total: 315 }], photos: [], paid: 500 };
  }
  var bgUrl = cfg.background.path ? (await C.signedUrls([cfg.background.path]).catch(function () { return {}; }))[cfg.background.path] : "";

  function preview() { data.bgUrl = bgUrl; document.getElementById("pv").innerHTML = DocRender.render(data, cfg); }
  function chk(k, v, lab) { return '<label style="display:flex;gap:6px;align-items:center;font-size:13px"><input type="checkbox" style="width:auto" data-b="' + k + '"' + (v ? " checked" : "") + ">" + lab + "</label>"; }

  view.innerHTML = UI.head("Document designer", "Each save creates a new version. Posted documents keep the version active when they were posted.", "") +
    '<div class="pill">' + TYPES.map(function (x) { return '<a href="document-designer.html?type=' + x[0] + '"' + (x[0] === ptype ? ' class="on"' : "") + ">" + x[1] + "</a>"; }).join("") + "</div>" +
    '<div class="rowTools"><label class="field"><span>Layout</span><select id="prof">' + (profiles.length ? profiles.map(function (p) { return '<option value="' + p.id + '"' + (prof && p.id === prof.id ? " selected" : "") + ">" + esc(p.name) + (p.is_active ? " (in use)" : "") + "</option>"; }).join("") : '<option value="">Built-in default</option>') + "</select></label>" +
      (canEdit ? '<button class="btn" id="newp">+ New layout</button>' + (prof ? '<button class="btn" id="dup">Duplicate</button>' + (!prof.is_active ? '<button class="btn" id="use">Use this layout</button>' : "") : "") : "") + "</div>" +
    '<div class="split" style="grid-template-columns:320px 1fr"><div class="panel"><div class="body" id="ctl">' +
      '<label class="field"><span>Preset</span><select id="preset"><option value="">—</option>' + Object.keys(PRESETS).map(function (k) { return "<option>" + k + "</option>"; }).join("") + "</select></label>" +
      '<label class="field"><span>Title (blank = automatic)</span><input data-k="title" value="' + esc(cfg.title) + '"></label>' +
      '<label class="field"><span>Orientation</span><select data-k="orientation"><option value="portrait">A4 portrait</option><option value="landscape"' + (cfg.orientation === "landscape" ? " selected" : "") + ">A4 landscape</option></select></label>" +
      '<label class="field"><span>Accent colour</span><input type="color" data-k="accent" value="' + esc(cfg.accent) + '"></label>' +
      '<label class="field"><span>Font size (pt)</span><input type="number" step="0.5" data-k="font_size" value="' + cfg.font_size + '"></label>' +
      '<label class="field"><span>Logo position</span><select data-k="logo.position">' + ["left", "center", "right"].map(function (x) { return "<option" + (cfg.logo.position === x ? " selected" : "") + ">" + x + "</option>"; }).join("") + "</select></label>" +
      '<label class="field"><span>Logo height (px)</span><input type="number" data-k="logo.size" value="' + cfg.logo.size + '"></label>' +
      '<h2 class="formSec">Blocks</h2>' + [["header", "Company header & logo"], ["customer", "Customer & TRN"], ["vehicle", "Vehicle"], ["lines", "Line table"], ["totals", "VAT, totals, paid & balance"], ["words", "Amount in words"], ["notes", "Notes"], ["terms", "Terms & warranty"], ["bank", "Bank details"], ["signature", "Signatures"], ["photos", "Photo grid"], ["footer", "Footer"]]
        .map(function (b) { return chk("blocks." + b[0], cfg.blocks[b[0]], b[1]); }).join("") +
      '<h2 class="formSec">Columns</h2>' + cfg.columns.map(function (c, i) { return '<div style="display:flex;gap:6px;align-items:center;margin-bottom:4px"><input type="checkbox" style="width:auto" aria-label="Show column ' + esc(c[1]) + '" data-col="' + i + '"' + (c[2] ? " checked" : "") + '><input aria-label="Label for column ' + (i + 1) + '" data-lab="' + i + '" value="' + esc(c[1]) + '" style="padding:4px 6px"></div>'; }).join("") +
      '<h2 class="formSec">Photos</h2><label class="field"><span>Per row</span><input type="number" min="1" max="6" data-k="photos.columns" value="' + cfg.photos.columns + '"></label>' +
      '<label class="field"><span>Maximum per category</span><input type="number" data-k="photos.max" value="' + cfg.photos.max + '"></label><label class="field"><span>Height (mm)</span><input type="number" data-k="photos.height" value="' + cfg.photos.height + '"></label>' +
      '<h2 class="formSec">Text</h2><label class="field"><span>Customer label</span><input data-k="labels.customer" value="' + esc(cfg.labels.customer) + '"></label>' +
      '<label class="field"><span>Left signature</span><input data-k="labels.signature_left" value="' + esc(cfg.labels.signature_left) + '"></label><label class="field"><span>Right signature</span><input data-k="labels.signature_right" value="' + esc(cfg.labels.signature_right) + '"></label>' +
      '<label class="field"><span>Custom text</span><textarea data-k="custom_text" rows="2">' + esc(cfg.custom_text) + '</textarea></label><label class="field"><span>Footer</span><input data-k="footer_text" value="' + esc(cfg.footer_text) + '"></label>' +
      '<label class="field"><span>Watermark</span><input data-k="watermark" value="' + esc(cfg.watermark) + '"></label>' +
      '<h2 class="formSec">Reference / background</h2><p style="font-size:12px;color:var(--mute);margin:0 0 6px">Upload your existing printed design (image) to use as a background, or a PDF for reference.</p>' +
      (canEdit ? '<label class="btn">Upload image / PDF<input id="bg" type="file" accept="image/*,application/pdf" class="hide"></label> ' : "") + (cfg.background.path ? '<button class="btn sm" id="bgx">Remove</button>' : "") +
      '<label class="field"><span>Background opacity</span><input type="number" step="0.05" min="0" max="1" data-k="background.opacity" value="' + cfg.background.opacity + '"></label>' +
      (canEdit ? '<label class="field"><span>Change note</span><input id="note" placeholder="What changed"></label><button class="btn pri" id="save" style="width:100%">Save new version' + (prof && !prof.is_active ? "" : " & use it") + "</button>" : '<p class="note">Designing needs the Design documents permission.</p>') +
      '<h2 class="formSec">Versions</h2>' + (versions.length ? versions.map(function (v) { return '<div class="hist"><b>v' + v.version + "</b>" + (prof.active_version_id === v.id ? " ✓ active" : canEdit ? ' <button class="btn sm" data-act="' + v.id + '">Activate</button>' : "") + "<em>" + C.when(v.created_at) + (v.change_note ? " · " + esc(v.change_note) : "") + "</em></div>"; }).join("") : '<p style="font-size:12px;color:var(--mute)">No saved versions — the built-in layout is used.</p>') +
    '</div></div><div class="docWrap" id="pv"></div></div>';
  preview();

  function set(path, val) { var o = cfg, ks = path.split("."); for (var i = 0; i < ks.length - 1; i++) o = o[ks[i]]; o[ks[ks.length - 1]] = val; }
  view.querySelectorAll("[data-k]").forEach(function (el) { el.oninput = el.onchange = function () { set(el.dataset.k, el.type === "number" ? Number(el.value) : el.value); preview(); }; });
  view.querySelectorAll("[data-b]").forEach(function (el) { el.onchange = function () { set(el.dataset.b, el.checked); preview(); }; });
  view.querySelectorAll("[data-col]").forEach(function (el) { el.onchange = function () { cfg.columns[+el.dataset.col][2] = el.checked; preview(); }; });
  view.querySelectorAll("[data-lab]").forEach(function (el) { el.oninput = function () { cfg.columns[+el.dataset.lab][1] = el.value; preview(); }; });
  document.getElementById("preset").onchange = function () { if (!this.value) return; var keep = cfg.background; cfg = DocRender.merge(PRESETS[this.value]); cfg.background = keep; saveHint(); };
  function saveHint() { preview(); C.flash("Preset applied to the preview. Save to keep it."); }
  document.getElementById("prof").onchange = function () { location.href = "document-designer.html?type=" + ptype + "&profile=" + this.value; };

  async function ensureProfile(name) {
    var r = await C.q(sb.from("document_profiles").insert({ organization_id: ctx.org, name: name, profile_type: ptype, is_active: !profiles.some(function (p) { return p.is_active; }), configuration: cfg, page_size: "A4", orientation: cfg.orientation, created_by: ctx.user.id }).select("*").single());
    return r;
  }
  async function saveVersion(p, activate) {
    var vid = await C.rpc("save_document_profile_version", { p_profile_id: p.id, p_configuration: cfg, p_change_note: (document.getElementById("note") || {}).value || "", p_activate: activate });
    await C.q(sb.from("document_profiles").update({ orientation: cfg.orientation }).eq("id", p.id));
    var back = await C.q(sb.from("document_profile_versions").select("id,configuration").eq("id", vid).single());
    if (JSON.stringify(back.configuration.blocks) !== JSON.stringify(cfg.blocks)) throw new Error("The saved version could not be confirmed.");
    return vid;
  }
  if (!canEdit) return;
  document.getElementById("save").onclick = async function () {
    var b = this; C.busy(b, true);
    try { var p = prof || await ensureProfile("My " + t3[1].toLowerCase());
      if (!prof) await C.q(sb.from("document_profiles").update({ is_active: true }).eq("id", p.id));
      await saveVersion(p, true); sessionStorage.setItem("bp.flash", "Layout saved and verified as a new version."); location.href = "document-designer.html?type=" + ptype + "&profile=" + p.id;
    } catch (e) { C.busy(b, false); C.flash(C.message(e), "err"); }
  };
  var np = document.getElementById("newp"); if (np) np.onclick = function () { UI.dialog({ title: "New layout", input: "", placeholder: "Layout name", okLabel: "Create", onOk: async function (n) {
    try { cfg = DocRender.merge({}); var p = await ensureProfile(n || "New layout"); await saveVersion(p, true); location.href = "document-designer.html?type=" + ptype + "&profile=" + p.id; } catch (e) { C.flash(C.message(e), "err"); } } }); };
  var dp = document.getElementById("dup"); if (dp) dp.onclick = async function () { try { var p = await C.q(sb.from("document_profiles").insert({ organization_id: ctx.org, name: prof.name + " (copy)", profile_type: ptype, is_active: false, configuration: cfg, page_size: "A4", orientation: cfg.orientation, created_by: ctx.user.id }).select("*").single());
    await saveVersion(p, true); location.href = "document-designer.html?type=" + ptype + "&profile=" + p.id; } catch (e) { C.flash(C.message(e), "err"); } };
  var us = document.getElementById("use"); if (us) us.onclick = async function () { try {
    await C.q(sb.from("document_profiles").update({ is_active: false }).eq("organization_id", ctx.org).eq("profile_type", ptype));
    await C.q(sb.from("document_profiles").update({ is_active: true }).eq("id", prof.id));
    var b = await C.q(sb.from("document_profiles").select("is_active").eq("id", prof.id).single()); if (!b.is_active) throw new Error("Could not be confirmed.");
    sessionStorage.setItem("bp.flash", "This layout is now used for new " + t3[1].toLowerCase() + "s."); location.reload(); } catch (e) { C.flash(C.message(e), "err"); } };
  view.querySelectorAll("[data-act]").forEach(function (b) { b.onclick = async function () { try { await C.rpc("activate_document_profile_version", { p_version_id: b.dataset.act }); sessionStorage.setItem("bp.flash", "Version activated for new documents."); location.reload(); } catch (e) { C.flash(C.message(e), "err"); } }; });
  var bg = document.getElementById("bg"); if (bg) bg.onchange = async function () { try {
    var a = await C.upload(ctx, bg.files[0], { folder: "designs", entity_type: "document_profile", entity_id: prof ? prof.id : null, category: "DESIGN_REFERENCE" });
    if (/^image\//.test(a.mime_type)) { cfg.background.path = a.storage_path; bgUrl = (await C.signedUrls([a.storage_path]))[a.storage_path]; preview(); C.flash("Background uploaded. Save a version to keep it."); }
    else { var u = (await C.signedUrls([a.storage_path]))[a.storage_path]; window.open(u, "_blank"); C.flash("PDF reference uploaded privately and opened in a new tab to design against."); }
    if (prof) await C.q(sb.from("document_profiles").update({ reference_attachment_id: a.id }).eq("id", prof.id));
  } catch (e) { C.flash(C.message(e), "err"); } };
  var bx = document.getElementById("bgx"); if (bx) bx.onclick = function () { cfg.background.path = ""; bgUrl = ""; preview(); };
  var fl = sessionStorage.getItem("bp.flash"); if (fl) { sessionStorage.removeItem("bp.flash"); C.flash(fl); }
});
