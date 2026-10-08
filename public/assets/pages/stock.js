UI.cloudPage("stock", async function (ctx, view) {
  var C = Cloud, sb = C.sb, esc = C.esc;
  var TYPES = [["inventory", "Inventory product"], ["non_inventory", "Non-inventory material"], ["service", "Service"], ["labour", "Labour"], ["outside_work", "Outside work"], ["package", "Package"], ["expense_item", "Expense item"]];
  var M = await C.masters(ctx, ["settings", "warehouses", "products", "companies"]);
  var cats = await C.q(sb.from("product_categories").select("*").eq("organization_id", ctx.org).order("name")).catch(function () { return []; });
  var tab = C.query("tab") || "products", canEdit = C.can("masters.edit"), canCreate = C.can("masters.create"), canAdj = C.can("stock.adjust");
  function tl(k) { return (TYPES.filter(function (x) { return x[0] === k; })[0] || [k, k])[1]; }
  function go(q) { history.replaceState(null, "", "stock.html?" + q); tab = C.query("tab") || "products"; route(); }

  async function route() {
    var id = C.query("id"), edit = C.query("edit");
    if (C.query("new") || edit) return form(edit ? M.products.filter(function (p) { return p.id === edit; })[0] : null);
    if (id) return detail(id);
    var tabs = '<div class="tabs">' + [["products", "Products & services"], ["stock", "Stock on hand"], ["ledger", "Stock ledger"], ["adjust", "Adjust / count"], ["transfer", "Transfer"]]
      .map(function (t) { return '<button data-t="' + t[0] + '"' + (tab === t[0] ? ' class="on"' : "") + ">" + t[1] + "</button>"; }).join("") + "</div>";
    view.innerHTML = UI.head("Products & stock", "Stock changes only through posted documents, adjustments and transfers.", canCreate ? '<button class="btn pri" id="add">+ Product / service</button>' : "") + tabs + '<div id="pane"><div class="empty">Loading…</div></div>';
    view.querySelectorAll("[data-t]").forEach(function (b) { b.onclick = function () { go("tab=" + b.dataset.t); }; });
    var a = document.getElementById("add"); if (a) a.onclick = function () { go("new=1"); };
    var pane = document.getElementById("pane");
    try { await PANES[tab](pane); } catch (e) { pane.innerHTML = '<div class="panel"><div class="empty">' + esc(C.message(e)) + "</div></div>"; }
  }

  var PANES = {
    products: async function (pane) {
      var q = "";
      function draw() {
        var rows = M.products.filter(function (p) { return !q || [p.sku, p.barcode, p.name, p.description].join(" ").toLowerCase().indexOf(q) >= 0; });
        pane.innerHTML = '<input id="pq" type="search" class="searchBox" placeholder="Search SKU, barcode, name" value="' + esc(q) + '" style="margin-bottom:12px">' +
          UI.table(["SKU", "Name", "Type", "Unit", "Purchase price", "Sale price", "Average cost", "Status"], rows.map(function (p) {
            return '<tr class="link" data-id="' + p.id + '"><td>' + esc(p.sku || "—") + "</td><td><b>" + esc(p.name) + "</b></td><td>" + tl(p.item_type) + "</td><td>" + esc(p.unit || "") +
              '</td><td class="n">' + C.money(p.purchase_price) + '</td><td class="n">' + C.money(p.sale_price) + '</td><td class="n">' + (C.can("profit.view") ? C.money(p.average_cost) : "••") + "</td><td>" + esc(p.status) + "</td></tr>"; }),
            "No products or services yet.");
        pane.querySelectorAll("tr[data-id]").forEach(function (tr) { tr.onclick = function () { go("id=" + tr.dataset.id); }; });
        var pq = document.getElementById("pq"); pq.oninput = function () { q = pq.value.toLowerCase(); var pos = pq.selectionStart; draw(); var n = document.getElementById("pq"); n.focus(); n.setSelectionRange(pos, pos); };
      }
      draw();
    },
    stock: async function (pane) {
      var rows = await C.rpc("rpt_stock", { p_org: ctx.org });
      var val = rows.reduce(function (a, r) { return a + Number(r.value); }, 0);
      pane.innerHTML = '<div class="kpis">' + UI.stat("Stock value", C.can("profit.view") ? C.money(val) : "••") + UI.stat("Items", rows.length) +
        UI.stat("Below minimum", rows.filter(function (r) { return Number(r.minimum_stock) > 0 && Number(r.quantity) < Number(r.minimum_stock); }).length) +
        UI.stat("Negative", rows.filter(function (r) { return Number(r.quantity) < 0; }).length) + "</div>" +
        UI.table(["SKU", "Item", "Warehouse", "Quantity", "Average cost", "Value", "Minimum", "Reorder"], rows.map(function (r) {
          var low = Number(r.minimum_stock) > 0 && Number(r.quantity) < Number(r.minimum_stock);
          return "<tr><td>" + esc(r.sku || "") + "</td><td>" + esc(r.name) + "</td><td>" + esc(r.warehouse || "—") + '</td><td class="n' + (low || Number(r.quantity) < 0 ? " due" : "") + '">' + Number(r.quantity) +
            '</td><td class="n">' + C.money(r.average_cost) + '</td><td class="n">' + C.money(r.value) + '</td><td class="n">' + Number(r.minimum_stock || 0) + '</td><td class="n">' + Number(r.reorder_quantity || 0) + "</td></tr>"; }),
          "No inventory items yet.");
    },
    ledger: async function (pane) {
      var inv = M.products.filter(function (p) { return p.item_type === "inventory"; }), pid = C.query("product") || (inv[0] || {}).id;
      if (!pid) { pane.innerHTML = '<div class="panel"><div class="empty">No inventory items yet.</div></div>'; return; }
      var mv = await C.q(sb.from("stock_movements").select("*").eq("organization_id", ctx.org).eq("product_id", pid).order("created_at"));
      var tx = mv.length ? await C.q(sb.from("transactions").select("id,document_no,transaction_type").in("id", mv.filter(function (m) { return m.transaction_id; }).map(function (m) { return m.transaction_id; }))) : [];
      var bal = 0;
      pane.innerHTML = '<div class="rowTools"><label class="field"><span>Item</span><select id="lp">' + inv.map(function (p) { return '<option value="' + p.id + '"' + (p.id === pid ? " selected" : "") + ">" + esc((p.sku ? p.sku + " · " : "") + p.name) + "</option>"; }).join("") + "</select></label></div>" +
        UI.table(["Date", "Document", "Reason", "Warehouse", "In", "Out", "Balance", "Unit cost"], mv.map(function (m) {
          bal += Number(m.quantity_in) - Number(m.quantity_out); var t = tx.filter(function (x) { return x.id === m.transaction_id; })[0];
          var w = M.warehouses.filter(function (x) { return x.id === m.warehouse_id; })[0];
          return "<tr><td>" + C.date(m.created_at) + "</td><td>" + (t ? '<a href="voucher-view.html?id=' + t.id + '">' + esc(t.document_no || "") + "</a>" : "—") + "</td><td>" + esc((m.reason || "").replace(/_/g, " ")) + "</td><td>" + esc(w ? w.name : "") +
            '</td><td class="n">' + (Number(m.quantity_in) || "") + '</td><td class="n">' + (Number(m.quantity_out) || "") + '</td><td class="n">' + bal + '</td><td class="n">' + C.money(m.unit_cost) + "</td></tr>"; }), "No movements for this item.");
      document.getElementById("lp").onchange = function () { go("tab=ledger&product=" + this.value); };
    },
    adjust: async function (pane) {
      if (!canAdj) { pane.innerHTML = '<div class="panel"><div class="empty">Stock adjustments need the Adjust stock permission.</div></div>'; return; }
      var inv = M.products.filter(function (p) { return p.item_type === "inventory" && p.status === "active"; });
      var bals = await C.rpc("rpt_stock", { p_org: ctx.org });
      pane.innerHTML = '<div class="panel"><form id="af" class="body form">' +
        '<label class="field span2"><span>Item *</span><select id="a_p">' + inv.map(function (p) { return '<option value="' + p.id + '">' + esc((p.sku ? p.sku + " · " : "") + p.name) + "</option>"; }).join("") + "</select></label>" +
        '<label class="field"><span>Warehouse *</span><select id="a_w">' + M.warehouses.map(function (w) { return '<option value="' + w.id + '">' + esc(w.name) + "</option>"; }).join("") + "</select></label>" +
        '<label class="field"><span>Reason *</span><select id="a_r"><option value="opening">Opening stock</option><option value="count">Stock count (enter counted qty)</option><option value="damage">Damage</option><option value="write_off">Write-off</option><option value="correction">Correction (+/-)</option></select></label>' +
        '<label class="field"><span id="a_ql">Quantity</span><input id="a_q" type="number" step="any" inputmode="decimal" required></label>' +
        '<label class="field"><span>Unit cost (for stock in)</span><input id="a_c" type="number" step="0.01"></label>' +
        '<label class="field span2"><span>Note</span><input id="a_n"></label>' +
        '<p id="a_cur" class="span4" style="grid-column:1/-1;font-size:12.5px;color:var(--mute);margin:0 0 10px"></p>' +
        '<div class="span4" style="grid-column:1/-1"><button class="btn pri" id="a_go" type="submit">Post adjustment</button></div></form></div>';
      function cur() { var p = document.getElementById("a_p").value, w = document.getElementById("a_w").value;
        var b = bals.filter(function (x) { return x.product_id === p && M.warehouses.some(function (h) { return h.id === w && h.name === x.warehouse; }); })[0];
        return b ? Number(b.quantity) : 0; }
      function hint() { var r = document.getElementById("a_r").value; document.getElementById("a_ql").textContent = r === "count" ? "Counted quantity" : r === "correction" ? "Change (+ in / − out)" : "Quantity";
        document.getElementById("a_cur").textContent = "On hand now: " + cur() + ". Damage and write-off reduce stock; opening stock increases it."; }
      ["a_p", "a_w", "a_r"].forEach(function (i) { document.getElementById(i).onchange = hint; }); hint();
      var key = C.uuid();
      document.getElementById("af").onsubmit = async function (e) {
        e.preventDefault(); var btn = document.getElementById("a_go");
        var r = document.getElementById("a_r").value, q = Number(document.getElementById("a_q").value), before = cur(), delta;
        if (!(r === "correction" ? q !== 0 : r === "count" ? q >= 0 : q > 0)) return C.flash("Enter a valid quantity.", "err");
        delta = r === "count" ? q - before : r === "damage" || r === "write_off" ? -q : q;
        if (delta === 0) return C.flash("Counted quantity equals the stock on hand. Nothing to adjust.", "err");
        C.busy(btn, true, "Posting…");
        try {
          await C.rpc("create_stock_adjustment", { p_org: ctx.org, p_product: document.getElementById("a_p").value, p_warehouse: document.getElementById("a_w").value, p_quantity_delta: delta,
            p_unit_cost: Number(document.getElementById("a_c").value) || null, p_note: (r.replace("_", " ") + ": " + (document.getElementById("a_n").value || "")).trim(), p_idempotency_key: key });
          bals = await C.rpc("rpt_stock", { p_org: ctx.org });
          if (Math.abs(cur() - (before + delta)) > 0.0001) throw new Error("The new stock level could not be confirmed.");
          C.flash("Adjustment posted and verified. On hand: " + cur()); key = C.uuid(); C.busy(btn, false); hint(); document.getElementById("a_q").value = "";
        } catch (err) { C.busy(btn, false); C.flash(C.message(err), "err"); }
      };
    },
    transfer: async function (pane) {
      if (!canAdj) { pane.innerHTML = '<div class="panel"><div class="empty">Transfers need the Adjust stock permission.</div></div>'; return; }
      if (M.warehouses.length < 2) { pane.innerHTML = '<div class="panel"><div class="empty">Add a second warehouse in <a href="settings.html?tab=warehouses">Settings</a> to transfer stock.</div></div>'; return; }
      var inv = M.products.filter(function (p) { return p.item_type === "inventory" && p.status === "active"; }), wopt = M.warehouses.map(function (w) { return '<option value="' + w.id + '">' + esc(w.name) + "</option>"; }).join("");
      pane.innerHTML = '<div class="panel"><form id="tf" class="body form"><label class="field span2"><span>Item</span><select id="t_p">' + inv.map(function (p) { return '<option value="' + p.id + '">' + esc(p.name) + "</option>"; }).join("") + "</select></label>" +
        '<label class="field"><span>From</span><select id="t_f">' + wopt + '</select></label><label class="field"><span>To</span><select id="t_t">' + wopt + "</select></label>" +
        '<label class="field"><span>Quantity</span><input id="t_q" type="number" step="any" required></label><label class="field span2"><span>Note</span><input id="t_n"></label>' +
        '<div style="grid-column:1/-1"><button class="btn pri" id="t_go" type="submit">Transfer</button></div></form></div>';
      var key = C.uuid();
      document.getElementById("tf").onsubmit = async function (e) {
        e.preventDefault(); var b = document.getElementById("t_go"), f = document.getElementById("t_f").value, t = document.getElementById("t_t").value;
        if (f === t) return C.flash("Choose two different warehouses.", "err");
        C.busy(b, true, "Posting…");
        try { await C.rpc("create_stock_transfer", { p_org: ctx.org, p_product: document.getElementById("t_p").value, p_from_warehouse: f, p_to_warehouse: t, p_quantity: Number(document.getElementById("t_q").value), p_note: document.getElementById("t_n").value, p_idempotency_key: key });
          C.flash("Transfer posted. See the stock ledger to confirm."); key = C.uuid(); C.busy(b, false);
        } catch (err) { C.busy(b, false); C.flash(C.message(err), "err"); }
      };
    }
  };

  function form(p) {
    var isNew = !p; p = p || { item_type: "inventory", unit: "pcs", status: "active", negative_stock_policy: "", default_warehouse_id: (M.warehouses[0] || {}).id };
    var F = [{ section: "Item" }, { k: "item_type", label: "Type", type: "select", opts: TYPES.map(function (t) { return { v: t[0], l: t[1] }; }), req: true },
      { k: "sku", label: "SKU", req: true }, { k: "barcode", label: "Barcode" }, { k: "unit", label: "Unit", list: "units" },
      { k: "name", label: "Name", req: true, span: 2 }, { k: "category_id", label: "Category", type: "select", opts: [{ v: "", l: "—" }].concat(cats.map(function (c) { return { v: c.id, l: c.name }; })) },
      { k: "status", label: "Status", type: "select", opts: [{ v: "active", l: "Active" }, { v: "inactive", l: "Inactive" }] },
      { k: "description", label: "Description", type: "textarea", span: 4 },
      { section: "Pricing" }, { k: "purchase_price", label: "Purchase price", type: "number" }, { k: "sale_price", label: "Sale price", type: "number" },
      { section: "Stock" }, { k: "default_warehouse_id", label: "Default warehouse", type: "select", opts: [{ v: "", l: "—" }].concat(M.warehouses.map(function (w) { return { v: w.id, l: w.name }; })) },
      { k: "minimum_stock", label: "Minimum stock", type: "number" }, { k: "reorder_quantity", label: "Reorder quantity", type: "number" },
      { k: "negative_stock_policy", label: "Negative stock", type: "select", opts: [{ v: "", l: "Company default (" + (M.settings.negative_stock_policy || "block") + ")" }, { v: "block", l: "Block" }, { v: "warn", l: "Warn" }, { v: "allow", l: "Allow" }] },
      { section: "Notes" }, { k: "notes", label: "Notes", type: "textarea", span: 4 }];
    view.innerHTML = UI.head(isNew ? "New product / service" : "Edit " + p.name, "Average cost is maintained by posted purchases; it is not typed in.", "") +
      '<div class="panel"><form id="pf"><div class="body form">' + C.fields(F, p) + '</div><datalist id="units"><option>pcs</option><option>set</option><option>ltr</option><option>kg</option><option>m</option><option>roll</option><option>hr</option><option>job</option></datalist>' +
      '<div class="formFoot"><a class="btn" href="stock.html">Cancel</a><button class="btn" type="button" id="newcat">+ Category</button><button class="btn pri" id="save" type="submit">Save</button></div></form></div>';
    document.getElementById("newcat").onclick = function () { UI.dialog({ title: "New category", input: "", placeholder: "e.g. Coatings", okLabel: "Add", onOk: async function (n) {
      if (!n.trim()) return; try { var c = await C.q(sb.from("product_categories").insert({ organization_id: ctx.org, name: n.trim(), code: n.trim().toUpperCase().slice(0, 12), created_by: ctx.user.id }).select("*").single());
        cats.push(c); var s = document.getElementById("f_category_id"); s.insertAdjacentHTML("beforeend", '<option value="' + c.id + '" selected>' + esc(c.name) + "</option>"); } catch (e) { C.flash(C.message(e), "err"); } } }); };
    document.getElementById("pf").onsubmit = async function (e) {
      e.preventDefault(); var b = document.getElementById("save"), d = C.collect(document.getElementById("pf"));
      if (!d.sku || !d.name) return C.flash("SKU and name are required.", "err");
      var row = { item_type: d.item_type, sku: d.sku, barcode: d.barcode || null, unit: d.unit || null, name: d.name, category_id: d.category_id || null, status: d.status, description: d.description || null,
        purchase_price: Number(d.purchase_price) || 0, sale_price: Number(d.sale_price) || 0, default_warehouse_id: d.default_warehouse_id || null, minimum_stock: Number(d.minimum_stock) || 0,
        reorder_quantity: Number(d.reorder_quantity) || 0, negative_stock_policy: d.negative_stock_policy || null, notes: d.notes || null, updated_at: new Date().toISOString() };
      C.busy(b, true);
      try {
        var r = isNew ? await C.q(sb.from("products").insert(Object.assign({ organization_id: ctx.org, created_by: ctx.user.id, average_cost: 0 }, row)).select("id").single())
                      : await C.q(sb.from("products").update(row).eq("id", p.id).select("id").single());
        var back = await C.q(sb.from("products").select("*").eq("id", r.id).single());
        if (back.sku !== row.sku || back.name !== row.name || Number(back.sale_price) !== row.sale_price || back.item_type !== row.item_type) throw new Error("The saved product does not match what was entered.");
        M.products = await C.q(sb.from("products").select("*").eq("organization_id", ctx.org).order("name"));
        C.flash("Saved and verified: " + back.sku); go("id=" + back.id);
      } catch (err) { C.busy(b, false); C.flash(/duplicate|unique/i.test(C.message(err)) ? "That SKU is already used." : C.message(err), "err"); }
    };
  }

  async function detail(id) {
    var p = M.products.filter(function (x) { return x.id === id; })[0];
    if (!p) { view.innerHTML = '<div class="panel"><div class="empty">Not found.</div></div>'; return; }
    var st = p.item_type === "inventory" ? (await C.rpc("rpt_stock", { p_org: ctx.org })).filter(function (r) { return r.product_id === id; }) : [];
    view.innerHTML = UI.head(p.name, esc(p.sku || "") + " · " + tl(p.item_type), '<a class="btn" href="stock.html">List</a> ' + (canEdit ? '<a class="btn pri" href="stock.html?edit=' + id + '">Edit</a>' : "")) +
      '<div class="panel">' + UI.kv([["Barcode", p.barcode], ["Unit", p.unit], ["Status", p.status], ["Purchase price", C.money(p.purchase_price)], ["Sale price", C.money(p.sale_price)],
        ["Average cost", C.can("profit.view") ? C.money(p.average_cost) : "••"], ["Minimum stock", p.minimum_stock], ["Reorder quantity", p.reorder_quantity], ["Negative stock", p.negative_stock_policy || "company default"],
        ["Description", p.description], ["Notes", p.notes]]) + "</div>" +
      (st.length ? '<h3 class="formSec">On hand</h3>' + UI.table(["Warehouse", "Quantity", "Value"], st.map(function (r) { return "<tr><td>" + esc(r.warehouse || "—") + '</td><td class="n">' + Number(r.quantity) + '</td><td class="n">' + C.money(r.value) + "</td></tr>"; })) +
        '<p><a href="stock.html?tab=ledger&product=' + id + '">Open stock ledger</a></p>' : "");
  }
  route();
});
