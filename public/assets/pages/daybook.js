UI.cloudPage("records", async function (ctx, view) {
  var C = Cloud, sb = C.sb, esc = C.esc;
  var f = { from: C.query("from") || C.monthStart(), to: C.query("to") || C.today(), type: C.query("type") || "", status: C.query("status") || "", q: C.query("q") || "" };
  var parties = await C.q(sb.from("parties").select("id,display_name,name").eq("organization_id", ctx.org));
  function pn(id) { var p = parties.filter(function (x) { return x.id === id; })[0]; return p ? C.partyName(p) : ""; }
  async function draw() {
    var qy = sb.from("transactions").select("id,document_no,transaction_type,transaction_date,party_id,grand_total,tax_total,status,created_at").eq("organization_id", ctx.org)
      .gte("transaction_date", f.from).lte("transaction_date", f.to).order("transaction_date", { ascending: false }).order("created_at", { ascending: false }).limit(1000);
    if (f.type) qy = qy.eq("transaction_type", f.type);
    if (f.status) qy = qy.eq("status", f.status);
    var rows = await C.q(qy);
    if (f.q) { var q = f.q.toLowerCase(); rows = rows.filter(function (t) { return ((t.document_no || "") + " " + pn(t.party_id) + " " + t.grand_total).toLowerCase().indexOf(q) >= 0; }); }
    var tot = rows.filter(function (t) { return t.status === "posted"; }).reduce(function (a, t) { return a + Number(t.grand_total); }, 0);
    view.innerHTML = UI.head("Day book", rows.length + " documents · posted total " + C.money(tot), '<a class="btn pri" href="new-transaction.html">+ New</a> <button class="btn" id="csv">CSV</button>') +
      '<div class="rowTools"><label class="field"><span>From</span><input type="date" id="from" value="' + f.from + '"></label><label class="field"><span>To</span><input type="date" id="to" value="' + f.to + '"></label>' +
      '<label class="field"><span>Type</span><select id="type"><option value="">All</option>' + Object.keys(C.TYPE_LABEL).map(function (k) { return '<option value="' + k + '"' + (f.type === k ? " selected" : "") + ">" + C.TYPE_LABEL[k] + "</option>"; }).join("") + "</select></label>" +
      '<label class="field"><span>Status</span><select id="status"><option value="">All</option>' + ["draft", "posted", "void"].map(function (s) { return '<option' + (f.status === s ? " selected" : "") + ">" + s + "</option>"; }).join("") + "</select></label>" +
      '<label class="field"><span>Find</span><input id="q" value="' + esc(f.q) + '" placeholder="Number, party, amount"></label></div>' +
      UI.table(["Number", "Date", "Type", "Party", "VAT", "Total", "Status"], rows.map(function (t) {
        return '<tr class="link" onclick="location.href=\'voucher-view.html?id=' + t.id + '\'"><td><b>' + esc(t.document_no || "Draft") + "</b></td><td>" + t.transaction_date + "</td><td>" + esc(C.TYPE_LABEL[t.transaction_type] || t.transaction_type) +
          "</td><td>" + esc(pn(t.party_id)) + '</td><td class="n">' + C.money(t.tax_total) + '</td><td class="n">' + C.money(t.grand_total) + "</td><td>" + UI.tag(t.status) + "</td></tr>"; }), "No documents in this period.");
    ["from", "to", "type", "status", "q"].forEach(function (k) { document.getElementById(k).onchange = function () { f[k] = this.value; history.replaceState(null, "", "day-book.html?" + new URLSearchParams(f)); draw(); }; });
    document.getElementById("csv").onclick = function () { UI.download("day-book-" + f.from + "-" + f.to + ".csv", UI.csv([["Number", "Date", "Type", "Party", "VAT", "Total", "Status"]].concat(rows.map(function (t) {
      return [t.document_no || "Draft", t.transaction_date, C.TYPE_LABEL[t.transaction_type], pn(t.party_id), t.tax_total, t.grand_total, t.status]; }))), "text/csv"); };
  }
  draw().catch(function (e) { view.innerHTML = '<div class="panel"><div class="empty">' + esc(C.message(e)) + "</div></div>"; });
});
