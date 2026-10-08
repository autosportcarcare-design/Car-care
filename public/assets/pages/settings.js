UI.cloudPage("settings", async function (ctx, view) {
  var C = Cloud, sb = C.sb, esc = C.esc;
  var tab = C.query("tab") || "company", canEdit = C.can("settings.edit");
  var TABS = [["company", "Company"], ["vat", "VAT & tax codes"], ["branches", "Branches"], ["warehouses", "Warehouses"], ["pay", "Payment methods"], ["accounts", "Chart of accounts"],
    ["numbering", "Numbering"], ["audit", "Audit log"], ["appearance", "Appearance"]];
  var M = await C.masters(ctx, ["settings", "companies", "branches", "warehouses", "tax", "pay"]);
  var accounts = await C.q(sb.from("accounts").select("*").eq("organization_id", ctx.org).order("code")).catch(function () { return []; });
  function go(t) { history.replaceState(null, "", "settings.html?tab=" + t); tab = t; draw(); }
  function ro() { return canEdit ? "" : '<div class="note">You can view settings. Changing them needs the Edit settings permission.</div>'; }
  async function reload() { M = await C.masters(ctx, ["settings", "companies", "branches", "warehouses", "tax", "pay"]); accounts = await C.q(sb.from("accounts").select("*").eq("organization_id", ctx.org).order("code")); }

  async function saveRow(table, id, row, verify) {
    var r = id ? await C.q(sb.from(table).update(row).eq("id", id).select("*").single()) : await C.q(sb.from(table).insert(Object.assign({ organization_id: ctx.org }, row)).select("*").single());
    var back = await C.q(sb.from(table).select("*").eq("id", r.id).single());
    (verify || Object.keys(row)).forEach(function (k) { if (String(back[k] == null ? "" : back[k]) !== String(row[k] == null ? "" : row[k])) throw new Error("Saved value for " + k + " could not be confirmed."); });
    return back;
  }
  function editor(title, fields, values, onSave) {
    UI.dialog({ title: title, wide: true, okLabel: "Save", keepOpen: true, html: '<form class="form" id="ed">' + C.fields(fields, values || {}) + "</form>",
      onOk: async function (wrap, close) { try { await onSave(C.collect(wrap.querySelector("#ed"))); close(); await reload(); draw(); C.flash("Saved and verified."); } catch (e) { C.flash(C.message(e), "err"); } } });
  }

  async function draw() {
    view.innerHTML = UI.head("Settings", esc(ctx.company.name), "") + '<div class="tabs">' + TABS.map(function (t) { return '<button data-t="' + t[0] + '"' + (t[0] === tab ? ' class="on"' : "") + ">" + t[1] + "</button>"; }).join("") + '</div><div id="pane"></div>';
    view.querySelectorAll("[data-t]").forEach(function (b) { b.onclick = function () { go(b.dataset.t); }; });
    var pane = document.getElementById("pane"), s = M.settings, x = s.settings || {};
    try {
      if (tab === "company") {
        var logo = s.logo_storage_path ? (await C.signedUrls([s.logo_storage_path]))[s.logo_storage_path] : "";
        pane.innerHTML = ro() + '<div class="panel"><form id="cf" class="body form">' + C.fields([{ section: "Identity" }, { k: "legal_name", label: "Legal name (trade licence)", span: 2 }, { k: "operating_name", label: "Trading name", span: 2 },
          { k: "tax_registration_no", label: "TRN (15 digits)" }, { k: "trade_licence", label: "Trade licence no." }, { k: "phone", label: "Phone" }, { k: "email", label: "Email", type: "email" },
          { k: "address", label: "Address", span: 4, type: "textarea" }, { k: "website", label: "Website", span: 2 }, { k: "currency", label: "Currency", hint: "Set when the company was created" },
          { section: "Documents" }, { k: "bank_details", label: "Bank details for invoices", type: "textarea", span: 2 }, { k: "terms", label: "Default terms & conditions", type: "textarea", span: 2 },
          { k: "warranty", label: "Warranty note", type: "textarea", span: 4 },
          { section: "Stock" }, { k: "negative_stock_policy", label: "Negative stock (company default)", type: "select", opts: [{ v: "block", l: "Block" }, { v: "warn", l: "Warn (needs override permission)" }, { v: "allow", l: "Allow" }] }],
          Object.assign({}, s, { trade_licence: x.trade_licence, bank_details: x.bank_details, terms: x.terms, warranty: x.warranty })) +
          '<div style="grid-column:1/-1;display:flex;gap:10px;align-items:center;flex-wrap:wrap">' + (logo ? '<img src="' + esc(logo) + '" alt="Company logo" style="max-height:60px">' : '<span style="font-size:12px;color:var(--mute)">No logo uploaded</span>') +
          (canEdit ? '<label class="btn">Upload logo<input type="file" id="logo" accept="image/*" class="hide"></label><span style="flex:1"></span><button class="btn pri" id="cs" type="submit">Save company</button>' : "") + "</div></form></div>";
        document.getElementById("f_currency").readOnly = true;
        var lg = document.getElementById("logo");
        if (lg) lg.onchange = async function () { try { var a = await C.upload(ctx, lg.files[0], { folder: "company", entity_type: "organization", entity_id: ctx.org, category: "LOGO" });
          await C.q(sb.from("organization_settings").update({ logo_storage_path: a.storage_path }).eq("organization_id", ctx.org));
          var b = await C.q(sb.from("organization_settings").select("logo_storage_path").eq("organization_id", ctx.org).single()); if (b.logo_storage_path !== a.storage_path) throw new Error("Logo could not be confirmed.");
          await reload(); draw(); C.flash("Logo saved and verified."); } catch (e) { C.flash(C.message(e), "err"); } };
        document.getElementById("cf").onsubmit = async function (e) {
          e.preventDefault(); if (!canEdit) return; var d = C.collect(document.getElementById("cf")), b = document.getElementById("cs");
          if (d.tax_registration_no && !/^\d{15}$/.test(d.tax_registration_no.replace(/\s/g, ""))) return C.flash("TRN must be exactly 15 digits.", "err");
          var row = { legal_name: d.legal_name || null, operating_name: d.operating_name || null, tax_registration_no: d.tax_registration_no.replace(/\s/g, "") || null, phone: d.phone || null, email: d.email || null,
            address: d.address || null, website: d.website || null, negative_stock_policy: d.negative_stock_policy, updated_by: ctx.user.id, updated_at: new Date().toISOString(),
            settings: Object.assign({}, x, { trade_licence: d.trade_licence, bank_details: d.bank_details, terms: d.terms, warranty: d.warranty }) };
          C.busy(b, true);
          try { await C.q(sb.from("organization_settings").update(row).eq("organization_id", ctx.org));
            var bk = await C.q(sb.from("organization_settings").select("*").eq("organization_id", ctx.org).single());
            if ((bk.legal_name || "") !== (row.legal_name || "") || (bk.tax_registration_no || "") !== (row.tax_registration_no || "") || (bk.settings || {}).terms !== row.settings.terms) throw new Error("Settings could not be confirmed.");
            await reload(); draw(); C.flash("Company settings saved and verified.");
          } catch (err) { C.busy(b, false); C.flash(C.message(err), "err"); }
        };
      }
      if (tab === "vat") {
        pane.innerHTML = ro() + '<div class="panel"><div class="body form">' +
          '<label class="field"><span>VAT</span><select id="v_on"' + (canEdit ? "" : " disabled") + '><option value="false">Off — no VAT charged</option><option value="true"' + (s.tax_enabled ? " selected" : "") + ">On</option></select></label>" +
          '<label class="field"><span>VAT registered</span><select id="v_reg"' + (canEdit ? "" : " disabled") + '><option value="false">No</option><option value="true"' + (s.tax_registered ? " selected" : "") + ">Yes</option></select></label>" +
          '<label class="field"><span>Prices entered</span><select id="v_incl"' + (canEdit ? "" : " disabled") + '><option value="false">Exclusive of VAT</option><option value="true"' + (s.prices_include_tax ? " selected" : "") + ">Inclusive of VAT</option></select></label>" +
          (canEdit ? '<div class="field" style="align-self:end"><button class="btn pri" id="v_save" style="width:100%">Save VAT settings</button></div>' : "") + "</div></div>" +
          '<h3 class="formSec">Tax codes</h3>' + (canEdit ? '<div class="rowTools"><button class="btn" id="t_add">+ Tax code</button>' + (M.tax.length ? "" : '<button class="btn" id="t_uae">Create UAE codes (5% standard, zero-rated, exempt, out of scope)</button>') + "</div>" : "") +
          UI.table(["Code", "Name", "Rate", "Classification", "Inclusive", "Input recoverable", "From", "To", "Status"], M.tax.map(function (t) {
            return '<tr class="link" data-tx="' + t.id + '"><td><b>' + esc(t.code) + "</b></td><td>" + esc(t.name) + '</td><td class="n">' + t.rate + "%</td><td>" + t.classification.replace(/_/g, " ") + "</td><td>" + (t.inclusive ? "Yes" : "No") + "</td><td>" + (t.input_recoverable_default ? "Yes" : "No") + "</td><td>" + t.effective_from + "</td><td>" + (t.effective_to || "") + "</td><td>" + t.status + "</td></tr>"; }), "No tax codes yet.");
        var TF = [{ k: "code", label: "Code", req: true }, { k: "name", label: "Name", req: true, span: 2 }, { k: "rate", label: "Rate %", type: "number" },
          { k: "classification", label: "Classification", type: "select", opts: [{ v: "taxable", l: "Standard (taxable)" }, { v: "zero_rated", l: "Zero-rated" }, { v: "exempt", l: "Exempt" }, { v: "out_of_scope", l: "Out of scope" }] },
          { k: "inclusive", label: "Rate is VAT-inclusive", type: "select", opts: [{ v: "false", l: "No" }, { v: "true", l: "Yes" }] }, { k: "input_recoverable_default", label: "Input VAT recoverable", type: "select", opts: [{ v: "true", l: "Yes" }, { v: "false", l: "No" }] },
          { k: "effective_from", label: "Effective from", type: "date", req: true }, { k: "effective_to", label: "Effective to", type: "date" }, { k: "status", label: "Status", type: "select", opts: ["active", "inactive"] }];
        function taxRow(d) { if (!d.code || !d.name || !d.effective_from) throw new Error("Code, name and effective date are required.");
          return { code: d.code, name: d.name, rate: Number(d.rate) || 0, classification: d.classification, inclusive: d.inclusive === "true", input_recoverable_default: d.input_recoverable_default === "true", effective_from: d.effective_from, effective_to: d.effective_to || null, status: d.status }; }
        if (canEdit) {
          document.getElementById("v_save").onclick = async function () {
            var row = { tax_enabled: document.getElementById("v_on").value === "true", tax_registered: document.getElementById("v_reg").value === "true", prices_include_tax: document.getElementById("v_incl").value === "true", updated_by: ctx.user.id, updated_at: new Date().toISOString() };
            try { await C.q(sb.from("organization_settings").update(row).eq("organization_id", ctx.org)); var b = await C.q(sb.from("organization_settings").select("tax_enabled,tax_registered").eq("organization_id", ctx.org).single());
              if (b.tax_enabled !== row.tax_enabled) throw new Error("Could not be confirmed."); await reload(); draw(); C.flash("VAT settings saved and verified."); } catch (e) { C.flash(C.message(e), "err"); } };
          document.getElementById("t_add").onclick = function () { editor("New tax code", TF, { rate: 5, classification: "taxable", effective_from: "2018-01-01", status: "active", input_recoverable_default: "true", inclusive: "false" }, function (d) { return saveRow("tax_codes", null, taxRow(d), ["code", "rate"]); }); };
          var ua = document.getElementById("t_uae"); if (ua) ua.onclick = async function () {
            try { for (var r of [["SR", "Standard rated 5%", 5, "taxable"], ["ZR", "Zero-rated", 0, "zero_rated"], ["EX", "Exempt", 0, "exempt"], ["OS", "Out of scope", 0, "out_of_scope"]])
                await saveRow("tax_codes", null, { code: r[0], name: r[1], rate: r[2], classification: r[3], inclusive: false, input_recoverable_default: true, effective_from: "2018-01-01", status: "active" }, ["code"]);
              await reload(); draw(); C.flash("UAE tax codes created and verified. Switch VAT on above when you are registered."); } catch (e) { C.flash(C.message(e), "err"); } };
          pane.querySelectorAll("[data-tx]").forEach(function (tr) { tr.onclick = function () { var t = M.tax.filter(function (x) { return x.id === tr.dataset.tx; })[0];
            editor("Edit " + t.code, TF, Object.assign({}, t, { inclusive: String(t.inclusive), input_recoverable_default: String(t.input_recoverable_default) }), function (d) { return saveRow("tax_codes", t.id, taxRow(d), ["code", "rate", "status"]); }); }; });
        }
      }
      if (tab === "branches" || tab === "warehouses" || tab === "pay") {
        var cfg = { branches: { t: "branches", list: M.branches, head: ["Code", "Name", "Address", "Default", "Status"], row: function (b) { return [b.code, b.name, b.address || "", b.is_default ? "Yes" : "", b.status]; },
            F: [{ k: "code", label: "Code", req: true }, { k: "name", label: "Name", req: true, span: 2 }, { k: "status", label: "Status", type: "select", opts: ["active", "inactive"] }, { k: "address", label: "Address", span: 4 }],
            mk: function (d) { return { code: d.code, name: d.name, address: d.address || null, status: d.status, company_id: (M.company || {}).id }; } },
          warehouses: { t: "warehouses", list: M.warehouses, head: ["Code", "Name", "Branch", "Status"], row: function (w) { return [w.code, w.name, (M.branches.filter(function (b) { return b.id === w.branch_id; })[0] || {}).name || "", w.status]; },
            F: [{ k: "code", label: "Code", req: true }, { k: "name", label: "Name", req: true, span: 2 }, { k: "status", label: "Status", type: "select", opts: ["active", "inactive"] },
              { k: "branch_id", label: "Branch", type: "select", opts: [{ v: "", l: "—" }].concat(M.branches.map(function (b) { return { v: b.id, l: b.name }; })) }],
            mk: function (d) { return { code: d.code, name: d.name, status: d.status, branch_id: d.branch_id || null, company_id: (M.company || {}).id }; } },
          pay: { t: "payment_methods", list: M.pay, head: ["Name", "Account"], row: function (p) { var a = accounts.filter(function (x) { return x.id === p.account_id; })[0]; return [p.name, a ? a.code + " " + a.name : ""]; },
            F: [{ k: "name", label: "Name", req: true, span: 2 }, { k: "account_id", label: "Cash/bank account", type: "select", opts: accounts.filter(function (a) { return a.account_type === "asset"; }).map(function (a) { return { v: a.id, l: a.code + " " + a.name }; }) }],
            mk: function (d) { return { name: d.name, account_id: d.account_id }; } } }[tab];
        pane.innerHTML = ro() + (canEdit ? '<div class="rowTools"><button class="btn pri" id="addr">+ Add</button></div>' : "") +
          UI.table(cfg.head, cfg.list.map(function (r) { return '<tr class="link" data-r="' + r.id + '">' + cfg.row(r).map(function (c) { return "<td>" + esc(c) + "</td>"; }).join("") + "</tr>"; }), "None yet.");
        if (canEdit) {
          document.getElementById("addr").onclick = function () { editor("Add", cfg.F, { status: "active" }, function (d) { if (!d.name) throw new Error("Name is required."); var r = cfg.mk(d); return saveRow(cfg.t, null, r, Object.keys(r).filter(function (k) { return k !== "company_id"; })); }); };
          pane.querySelectorAll("[data-r]").forEach(function (tr) { tr.onclick = function () { var r0 = cfg.list.filter(function (x) { return x.id === tr.dataset.r; })[0];
            editor("Edit " + (r0.name || ""), cfg.F, r0, function (d) { var r = cfg.mk(d); delete r.company_id; return saveRow(cfg.t, r0.id, r); }); }; });
        }
      }
      if (tab === "accounts") {
        pane.innerHTML = ro() + (canEdit ? '<div class="rowTools"><button class="btn pri" id="adda">+ Account</button></div>' : "") +
          UI.table(["Code", "Name", "Type", "System", "Status"], accounts.map(function (a) { return "<tr><td>" + esc(a.code) + "</td><td>" + esc(a.name) + "</td><td>" + a.account_type + "</td><td>" + (a.system_key ? "Yes" : "") + "</td><td>" + a.status + "</td></tr>"; }));
        if (canEdit) document.getElementById("adda").onclick = function () { editor("New account", [{ k: "code", label: "Code", req: true }, { k: "name", label: "Name", req: true, span: 2 },
          { k: "account_type", label: "Type", type: "select", opts: ["asset", "liability", "equity", "income", "cogs", "expense"] }], {}, function (d) {
          if (!d.code || !d.name) throw new Error("Code and name are required."); return saveRow("accounts", null, { code: d.code, name: d.name, account_type: d.account_type, status: "active" }, ["code", "name"]); }); };
      }
      if (tab === "numbering") {
        var seq = await C.q(sb.from("document_sequences").select("*").eq("organization_id", ctx.org).order("sequence_key"));
        pane.innerHTML = '<div class="note">Numbers are allocated by the database only when a document is posted. Trading, service and tax invoices share the INV series. Numbers cannot be edited, so there are no gaps or duplicates.</div>' +
          UI.table(["Series", "Prefix", "Next number"], seq.map(function (q) { return "<tr><td>" + esc(q.sequence_key.replace(/_/g, " ")) + "</td><td>" + esc(q.prefix) + "</td><td>" + esc(q.prefix + String(q.next_number).padStart(q.padding, "0")) + "</td></tr>"; }));
      }
      if (tab === "audit") {
        if (!C.can("audit.view")) { pane.innerHTML = '<div class="panel"><div class="empty">The audit log needs the View audit trail permission.</div></div>'; return; }
        var logs = await C.q(sb.from("audit_log").select("*").eq("organization_id", ctx.org).order("created_at", { ascending: false }).limit(500));
        var users = await C.rpc("company_members", { p_org: ctx.org }).catch(function () { return []; });
        pane.innerHTML = '<div class="note">Audit entries are written by the database and cannot be edited. Latest 500 shown.</div>' + UI.table(["When", "User", "Action", "Record"], logs.map(function (l) {
          var u = users.filter(function (x) { return x.user_id === l.actor_id; })[0];
          return "<tr><td>" + C.when(l.created_at) + "</td><td>" + esc(u ? u.email : (l.actor_id || "system").slice(0, 8)) + "</td><td>" + esc(l.action) + "</td><td>" + esc(l.resource_type) + " " + esc(String(l.resource_id || "").slice(0, 8)) + "</td></tr>"; }));
      }
      if (tab === "appearance") {
        pane.innerHTML = '<div class="panel"><div class="body"><p>Theme is kept on this device.</p><button class="btn" onclick="UI.toggleTheme()">Switch light / dark</button>' +
          '<p style="margin-top:14px;font-size:12.5px;color:var(--mute)">Install on iPhone: open this site in Safari, tap Share, then <b>Add to Home Screen</b>. Financial posting always needs an internet connection.</p></div></div>';
      }
    } catch (e) { pane.innerHTML = '<div class="panel"><div class="empty">' + esc(C.message(e)) + "</div></div>"; }
  }
  draw();
});
