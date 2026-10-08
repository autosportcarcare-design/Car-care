UI.cloudPage("reports", async function (ctx, view) {
  var C = Cloud, sb = C.sb, esc = C.esc;
  var LIST = [["tb", "Trial balance", "Accounting"], ["pl", "Profit & loss", "Accounting"], ["bs", "Balance sheet", "Accounting"], ["cf", "Cash flow", "Accounting"],
    ["gl", "General ledger", "Accounting"], ["party", "Customer / supplier ledger", "Accounting"], ["cash", "Cash book", "Accounting"], ["bank", "Bank book", "Accounting"], ["journal", "Journal", "Accounting"],
    ["sales", "Sales register", "Sales & purchases"], ["purchases", "Purchase register", "Sales & purchases"], ["expenses", "Expense register", "Sales & purchases"],
    ["vat", "VAT summary", "VAT"], ["ageing", "Receivables ageing", "AR / AP"], ["apageing", "Payables ageing", "AR / AP"],
    ["stock", "Stock summary & valuation", "Inventory"], ["reorder", "Reorder list", "Inventory"], ["profit", "Invoice profit", "Profit"], ["service", "Service profit & job register", "Profit"]];
  var M = await C.masters(ctx, ["parties", "settings"]);
  var accounts = await C.q(sb.from("accounts").select("*").eq("organization_id", ctx.org).order("code")).catch(function () { return []; });
  var f = { r: C.query("r") || "tb", from: C.query("from") || C.yearStart(), to: C.query("to") || C.today(), account: C.query("account") || "", party: C.query("party") || "" };
  var cur = M.settings.currency || "AED", out = null;
  function n(v) { return C.money(v); }
  function sysAcc(k) { return accounts.filter(function (a) { return a.system_key === k; })[0]; }
  function bal(rows, types, sign) { return rows.filter(function (r) { return types.indexOf(r.account_type) >= 0; }).map(function (r) { return { r: r, v: sign * Number(r.closing), p: sign * (Number(r.debit) - Number(r.credit)) }; }); }

  var R = {
    tb: async function () {
      var rows = (await C.rpc("rpt_account_balances", { p_org: ctx.org, p_from: f.from, p_to: f.to })).filter(function (r) { return Number(r.opening) || Number(r.debit) || Number(r.credit) || Number(r.closing); });
      var d = 0, c = 0, body = rows.map(function (r) { var cl = Number(r.closing); if (cl >= 0) d += cl; else c -= cl; return [r.code, r.name, r.account_type, n(r.opening), n(r.debit), n(r.credit), cl >= 0 ? n(cl) : "", cl < 0 ? n(-cl) : ""]; });
      return { head: ["Code", "Account", "Type", "Opening", "Period debit", "Period credit", "Closing debit", "Closing credit"], rows: body, total: ["", "Total", "", "", "", "", n(d), n(c)],
        note: Math.abs(d - c) < 0.005 ? '<span class="verified">Balanced: debits equal credits (' + n(d) + ").</span>" : '<span class="due">NOT BALANCED — difference ' + n(d - c) + "</span>" };
    },
    pl: async function () {
      var rows = await C.rpc("rpt_account_balances", { p_org: ctx.org, p_from: f.from, p_to: f.to });
      var inc = bal(rows, ["income"], -1), cogs = bal(rows, ["cogs"], 1), exp = bal(rows, ["expense"], 1), body = [], ti = 0, tc = 0, te = 0;
      body.push(["Income", "", ""]); inc.forEach(function (x) { if (x.p) { body.push(["", x.r.code + " " + x.r.name, n(x.p)]); ti += x.p; } }); body.push(["", "Total income", n(ti)]);
      body.push(["Cost of sales", "", ""]); cogs.forEach(function (x) { if (x.p) { body.push(["", x.r.code + " " + x.r.name, n(x.p)]); tc += x.p; } }); body.push(["", "Gross profit", n(ti - tc)]);
      body.push(["Expenses", "", ""]); exp.forEach(function (x) { if (x.p) { body.push(["", x.r.code + " " + x.r.name, n(x.p)]); te += x.p; } }); body.push(["", "Total expenses", n(te)]);
      return { head: ["Section", "Account", "Amount " + cur], rows: body, total: ["", "Net profit", n(ti - tc - te)], sub: function (r) { return r[1] === "" || /^Total|^Gross/.test(r[1]); } };
    },
    bs: async function () {
      var rows = await C.rpc("rpt_account_balances", { p_org: ctx.org, p_from: f.to, p_to: f.to });
      var a = bal(rows, ["asset"], 1), l = bal(rows, ["liability"], -1), e = bal(rows, ["equity"], -1);
      var profit = rows.filter(function (r) { return ["income", "cogs", "expense"].indexOf(r.account_type) >= 0; }).reduce(function (s, r) { return s - Number(r.closing); }, 0);
      var body = [], ta = 0, tl = 0, te = 0;
      body.push(["Assets", "", ""]); a.forEach(function (x) { if (x.v) { body.push(["", x.r.code + " " + x.r.name, n(x.v)]); ta += x.v; } }); body.push(["", "Total assets", n(ta)]);
      body.push(["Liabilities", "", ""]); l.forEach(function (x) { if (x.v) { body.push(["", x.r.code + " " + x.r.name, n(x.v)]); tl += x.v; } }); body.push(["", "Total liabilities", n(tl)]);
      body.push(["Equity", "", ""]); e.forEach(function (x) { if (x.v) { body.push(["", x.r.code + " " + x.r.name, n(x.v)]); te += x.v; } });
      body.push(["", "Retained profit to date", n(profit)]); te += profit; body.push(["", "Total equity", n(te)]);
      var ok = Math.abs(ta - tl - te) < 0.005;
      return { head: ["Section", "Account", "Amount " + cur], rows: body, total: ["", "Liabilities + equity", n(tl + te)], sub: function (r) { return r[1] === "" || /^Total/.test(r[1]); },
        note: (ok ? '<span class="verified">Balances: assets ' + n(ta) + " = liabilities + equity.</span>" : '<span class="due">Does not balance — difference ' + n(ta - tl - te) + "</span>") + " As at " + f.to + "." };
    },
    cf: async function () {
      var ids = accounts.filter(function (a) { return a.system_key === "cash" || a.system_key === "bank"; }).map(function (a) { return a.id; }), map = {}, open = 0, close = 0;
      for (var i = 0; i < ids.length; i++) {
        var L = await C.rpc("rpt_ledger", { p_org: ctx.org, p_account: ids[i], p_party: null, p_from: f.from, p_to: f.to });
        L.forEach(function (x) { if (x.is_opening) { open += Number(x.balance); return; } var k = C.TYPE_LABEL[x.transaction_type] || "Other"; map[k] = map[k] || { i: 0, o: 0 }; map[k].i += Number(x.debit); map[k].o += Number(x.credit); });
      }
      var body = Object.keys(map).sort().map(function (k) { close += map[k].i - map[k].o; return [k, n(map[k].i), n(map[k].o), n(map[k].i - map[k].o)]; });
      return { head: ["Activity", "Money in", "Money out", "Net"], rows: [["Opening cash + bank", "", "", n(open)]].concat(body), total: ["Closing cash + bank", "", "", n(open + close)] };
    },
    gl: async function () { return ledger(f.account || (accounts[0] || {}).id, null, true); },
    party: async function () { return f.party ? ledger(null, f.party) : { head: [], rows: [], empty: "Choose a customer or supplier above." }; },
    cash: async function () { var a = sysAcc("cash"); return a ? ledger(a.id) : { head: [], rows: [], empty: "No cash account." }; },
    bank: async function () { var a = sysAcc("bank"); return a ? ledger(a.id) : { head: [], rows: [], empty: "No bank account." }; },
    journal: async function () {
      var js = await C.q(sb.from("journals").select("id,journal_date,transaction_id,status").eq("organization_id", ctx.org).gte("journal_date", f.from).lte("journal_date", f.to).order("journal_date").limit(2000));
      if (!js.length) return { head: [], rows: [], empty: "No journals in this period." };
      var lines = await C.q(sb.from("journal_lines").select("*").in("journal_id", js.map(function (j) { return j.id; })));
      var tx = await C.q(sb.from("transactions").select("id,document_no,transaction_type").in("id", js.map(function (j) { return j.transaction_id; }).filter(Boolean)));
      var body = [], d = 0, c = 0;
      js.forEach(function (j) { var t = tx.filter(function (x) { return x.id === j.transaction_id; })[0] || {};
        lines.filter(function (l) { return l.journal_id === j.id; }).forEach(function (l) { var a = accounts.filter(function (x) { return x.id === l.account_id; })[0] || {};
          d += Number(l.debit); c += Number(l.credit); body.push([j.journal_date, t.document_no || "", a.code + " " + a.name, l.description || "", Number(l.debit) ? n(l.debit) : "", Number(l.credit) ? n(l.credit) : ""]); }); });
      return { head: ["Date", "Document", "Account", "Description", "Debit", "Credit"], rows: body, total: ["", "", "", "Total", n(d), n(c)] };
    },
    sales: async function () { return register(["sale", "service_sale", "mixed_sale", "credit_note"]); },
    purchases: async function () { return register(["purchase", "debit_note"]); },
    expenses: async function () { return register(["expense"]); },
    vat: async function () {
      var rows = await C.rpc("rpt_vat", { p_org: ctx.org, p_from: f.from, p_to: f.to }), o = 0, i = 0, nr = 0;
      var body = rows.map(function (r) { if (r.direction === "output") o += Number(r.tax); else if (r.recoverable) i += Number(r.tax); else nr += Number(r.tax);
        return [r.direction === "output" ? "Output (sales)" : "Input (purchases)", r.classification.replace(/_/g, " "), Number(r.rate) + "%", r.direction === "input" ? (r.recoverable ? "Recoverable" : "Not recoverable") : "", r.documents, n(r.net), n(r.tax)]; });
      return { head: ["Direction", "Classification", "Rate", "Input VAT", "Documents", "Taxable amount", "VAT"], rows: body, total: ["Net VAT payable", "", "", "", "", "", n(o - i)],
        note: "Output VAT " + n(o) + " · recoverable input VAT " + n(i) + (nr ? " · non-recoverable " + n(nr) : "") + ". Posted documents only. File your return through the FTA portal." };
    },
    ageing: async function () { return ageing("receivable"); },
    apageing: async function () { return ageing("payable"); },
    stock: async function () {
      var rows = await C.rpc("rpt_stock", { p_org: ctx.org }), v = 0;
      return { head: ["SKU", "Item", "Warehouse", "Quantity", "Average cost", "Value"], rows: rows.map(function (r) { v += Number(r.value); return [r.sku || "", r.name, r.warehouse || "", Number(r.quantity), n(r.average_cost), n(r.value)]; }), total: ["", "Stock value", "", "", "", n(v)] };
    },
    reorder: async function () {
      var rows = (await C.rpc("rpt_stock", { p_org: ctx.org })), by = {};
      rows.forEach(function (r) { by[r.product_id] = by[r.product_id] || { r: r, q: 0 }; by[r.product_id].q += Number(r.quantity); });
      var list = Object.values(by).filter(function (x) { return Number(x.r.minimum_stock) > 0 && x.q < Number(x.r.minimum_stock); });
      return { head: ["SKU", "Item", "On hand", "Minimum", "Suggested order"], rows: list.map(function (x) { return [x.r.sku || "", x.r.name, x.q, Number(x.r.minimum_stock), Number(x.r.reorder_quantity) || Number(x.r.minimum_stock) - x.q]; }), empty: "Nothing below minimum stock." };
    },
    profit: async function () { return profit(null); },
    service: async function () {
      var p = await profit("service_sale");
      var jobs = await C.q(sb.from("service_jobs").select("job_no,status,opened_date,plate_no,vehicle_make,vehicle_model,customer_id").eq("organization_id", ctx.org).gte("opened_date", f.from).lte("opened_date", f.to).order("opened_date"));
      p.after = '<h3 class="formSec">Job register (' + jobs.length + ")</h3>" + UI.table(["Job", "Opened", "Customer", "Vehicle", "Status"], jobs.map(function (j) {
        return "<tr><td>" + esc(j.job_no) + "</td><td>" + j.opened_date + "</td><td>" + esc(C.partyName(M.parties.filter(function (x) { return x.id === j.customer_id; })[0])) + "</td><td>" + esc([j.plate_no, j.vehicle_make, j.vehicle_model].filter(Boolean).join(" ")) + "</td><td>" + UI.tag(j.status) + "</td></tr>"; }), "No jobs opened in this period.");
      return p;
    }
  };
  async function ledger(acc, party) {
    var L = await C.rpc("rpt_ledger", { p_org: ctx.org, p_account: acc || null, p_party: party || null, p_from: f.from, p_to: f.to }), d = 0, c = 0, last = 0;
    return { head: ["Date", "Document", "Type", "Description", "Debit", "Credit", "Balance"], rows: L.map(function (x) { if (!x.is_opening) { d += Number(x.debit); c += Number(x.credit); } last = Number(x.balance);
      return [x.line_date, x.document_no || "", x.is_opening ? "" : (C.TYPE_LABEL[x.transaction_type] || ""), x.description, Number(x.debit) ? n(x.debit) : "", Number(x.credit) ? n(x.credit) : "", n(x.balance) + (Number(x.balance) < 0 ? " Cr" : " Dr")]; }),
      total: ["", "", "", "Period totals / closing", n(d), n(c), n(last) + (last < 0 ? " Cr" : " Dr")], links: L.map(function (x) { return x.transaction_id; }) };
  }
  async function register(types) {
    var t = await C.q(sb.from("transactions").select("id,document_no,transaction_type,transaction_date,party_id,subtotal,tax_total,grand_total,status").eq("organization_id", ctx.org).eq("status", "posted").in("transaction_type", types).gte("transaction_date", f.from).lte("transaction_date", f.to).order("transaction_date"));
    var a = 0, b = 0, c = 0;
    return { head: ["Date", "Number", "Type", "Party", "Net", "VAT", "Total"], rows: t.map(function (x) { var s = /credit_note|debit_note/.test(x.transaction_type) ? -1 : 1; a += s * x.subtotal; b += s * x.tax_total; c += s * x.grand_total;
      return [x.transaction_date, x.document_no, C.TYPE_LABEL[x.transaction_type], C.partyName(M.parties.filter(function (p) { return p.id === x.party_id; })[0]), n(s * x.subtotal), n(s * x.tax_total), n(s * x.grand_total)]; }),
      total: ["", "", "", "Total", n(a), n(b), n(c)], links: t.map(function (x) { return x.id; }) };
  }
  async function ageing(kind) {
    var rows = await C.rpc("rpt_open_items", { p_org: ctx.org, p_kind: kind, p_party: f.party || null }), B = [0, 0, 0, 0, 0];
    function bucket(d) { return d <= 0 ? 0 : d <= 30 ? 1 : d <= 60 ? 2 : d <= 90 ? 3 : 4; }
    return { head: ["Party", "Document", "Date", "Due", "Days overdue", "Original", "Paid", "Outstanding"], rows: rows.map(function (r) { B[bucket(r.days_overdue)] += Number(r.outstanding);
      return [r.party_name, r.document_no, r.doc_date, r.due_date || "", r.days_overdue, n(r.original), n(r.allocated), n(r.outstanding)]; }),
      total: ["Total", "", "", "", "", "", "", n(B.reduce(function (a, b) { return a + b; }, 0))], links: rows.map(function (r) { return r.transaction_id; }),
      note: "Current " + n(B[0]) + " · 1–30 days " + n(B[1]) + " · 31–60 " + n(B[2]) + " · 61–90 " + n(B[3]) + " · over 90 " + n(B[4]), empty: "Nothing outstanding." };
  }
  async function profit(type) {
    var rows = (await C.rpc("rpt_invoice_profit", { p_org: ctx.org, p_from: f.from, p_to: f.to })).filter(function (r) { return !type || r.transaction_type === type; }), a = 0, b = 0, c = 0;
    return { head: ["Invoice", "Date", "Customer", "Vehicle", "Revenue", "Stock cost", "Direct cost", "Profit", "Margin %"], rows: rows.map(function (r) { a += Number(r.revenue); b += Number(r.stock_cost) + Number(r.direct_cost); c += Number(r.profit);
      return [r.document_no, r.doc_date, r.party_name || "", r.vehicle || "", n(r.revenue), n(r.stock_cost), n(r.direct_cost), n(r.profit), r.margin]; }),
      total: ["Total", "", "", "", n(a), "", n(b), n(c), a ? Math.round(c / a * 1000) / 10 : 0], links: rows.map(function (r) { return r.transaction_id; }), empty: "No posted invoices in this period." };
  }

  async function draw() {
    var groups = {}, sel = "";
    LIST.forEach(function (x) { (groups[x[2]] = groups[x[2]] || []).push(x); });
    Object.keys(groups).forEach(function (g) { sel += '<optgroup label="' + g + '">' + groups[g].map(function (x) { return '<option value="' + x[0] + '"' + (x[0] === f.r ? " selected" : "") + ">" + x[1] + "</option>"; }).join("") + "</optgroup>"; });
    var title = (LIST.filter(function (x) { return x[0] === f.r; })[0] || LIST[0])[1];
    view.innerHTML = UI.head(title, esc(ctx.company.name) + " · " + (f.r === "bs" ? "as at " + f.to : f.from + " to " + f.to) + " · posted documents only", '<button class="btn" id="csv">CSV</button> <button class="btn" id="xlsx">Excel</button> <button class="btn pri" id="print">Print / PDF</button>') +
      '<div class="rowTools noprint"><label class="field"><span>Report</span><select id="r">' + sel + "</select></label>" +
      (["bs", "stock", "reorder", "ageing", "apageing"].indexOf(f.r) < 0 ? '<label class="field"><span>From</span><input type="date" id="from" value="' + f.from + '"></label>' : "") +
      (["stock", "reorder", "ageing", "apageing"].indexOf(f.r) < 0 ? '<label class="field"><span>' + (f.r === "bs" ? "As at" : "To") + '</span><input type="date" id="to" value="' + f.to + '"></label>' : "") +
      (f.r === "gl" ? '<label class="field"><span>Account</span><select id="account">' + accounts.map(function (a) { return '<option value="' + a.id + '"' + (a.id === f.account ? " selected" : "") + ">" + esc(a.code + " " + a.name) + "</option>"; }).join("") + "</select></label>" : "") +
      (["party", "ageing", "apageing"].indexOf(f.r) >= 0 ? '<label class="field"><span>Party</span><select id="party"><option value="">' + (f.r === "party" ? "Choose…" : "All") + "</option>" + M.parties.map(function (p) { return '<option value="' + p.id + '"' + (p.id === f.party ? " selected" : "") + ">" + esc(C.partyName(p)) + "</option>"; }).join("") + "</select></label>" : "") +
      '</div><div id="out"><div class="panel"><div class="empty">Calculating from the database…</div></div></div>';
    ["r", "from", "to", "account", "party"].forEach(function (k) { var el = document.getElementById(k); if (el) el.onchange = function () { f[k] = el.value; if (k === "r") { f.party = ""; } history.replaceState(null, "", "reports.html?" + new URLSearchParams(f)); draw(); }; });
    document.getElementById("print").onclick = function () { window.print(); };
    document.getElementById("csv").onclick = function () { if (out) UI.download(f.r + "-" + f.to + ".csv", UI.csv([out.head].concat(out.rows).concat(out.total ? [out.total] : [])), "text/csv"); };
    document.getElementById("xlsx").onclick = function () { if (out) UI.xlsx(f.r + "-" + f.to + ".xlsx", [[title, ctx.company.name, f.from + " to " + f.to], []].concat([out.head]).concat(out.rows).concat(out.total ? [out.total] : []), title); };
    try {
      out = await R[f.r]();
      var numCol = function (h) { return /Amount|Debit|Credit|Balance|Opening|Closing|Net|VAT|Total|Revenue|cost|Profit|Margin|Outstanding|Paid|Original|Quantity|Value|Money|Days|On hand|Minimum|Suggested|Documents|Taxable/i.test(h); };
      document.getElementById("out").innerHTML = (out.note ? '<div class="note">' + out.note + "</div>" : "") +
        (out.rows.length ? '<div class="panel"><div class="scroll"><table><thead><tr>' + out.head.map(function (h) { return "<th" + (numCol(h) ? ' class="n"' : "") + ">" + esc(h) + "</th>"; }).join("") + "</tr></thead><tbody>" +
          out.rows.map(function (r, i) { var link = out.links && out.links[i];
            return "<tr" + (out.sub && out.sub(r) ? ' class="sub"' : "") + (link ? ' class="link" onclick="location.href=\'voucher-view.html?id=' + link + '\'"' : "") + ">" + r.map(function (c, k) { return "<td" + (numCol(out.head[k]) ? ' class="n"' : "") + ">" + esc(c) + "</td>"; }).join("") + "</tr>"; }).join("") +
          (out.total ? '<tr class="tot">' + out.total.map(function (c, k) { return "<td" + (numCol(out.head[k]) ? ' class="n"' : "") + ">" + esc(c) + "</td>"; }).join("") + "</tr>" : "") + "</tbody></table></div></div>"
          : '<div class="panel"><div class="empty">' + (out.empty || "No posted entries in this period.") + "</div></div>") + (out.after || "");
    } catch (e) { document.getElementById("out").innerHTML = '<div class="panel"><div class="empty">' + esc(C.message(e)) + "</div></div>"; }
  }
  draw();
});
