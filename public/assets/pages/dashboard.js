UI.cloudPage("dashboard", async function (ctx, view) {
  var C = Cloud, esc = C.esc;
  var d = await C.rpc("rpt_dashboard", { p_org: ctx.org });
  function m(v) { return v == null ? "—" : C.money(v); }
  view.innerHTML = UI.head(ctx.company.name, "Live from the company database · " + C.today(), '<a class="btn pri" href="new-transaction.html?type=service_sale">+ Invoice</a> <a class="btn" href="job-cards.html?new=1">+ Job card</a>') +
    '<div class="kpis">' + UI.stat("Sales this month", m(d.sales_month)) + UI.stat("Receivable", m(d.receivable), "", Number(d.receivable) > 0) +
      UI.stat("Payable", m(d.payable)) + UI.stat("Cash + bank", m(d.cash_bank)) + "</div>" +
    '<div class="kpis">' + UI.stat("Open job cards", d.open_jobs, '<a href="job-cards.html">Open</a>') + UI.stat("Low stock items", d.low_stock, '<a href="reports.html?r=stock">Check</a>', d.low_stock > 0) +
      UI.stat("Draft documents", d.drafts == null ? "—" : d.drafts, '<a href="day-book.html?status=draft">Review</a>', d.drafts > 0) + UI.stat("Customers · vehicles", d.customers + " · " + d.vehicles) + "</div>" +
    '<div class="panel" style="margin-bottom:12px"><h2>Quick actions</h2><div class="body" style="display:flex;gap:8px;flex-wrap:wrap">' +
      UI.QUICK.map(function (q) { return '<a class="btn" href="' + q[1] + '">+ ' + q[0] + "</a>"; }).join("") + "</div></div>" +
    (d.recent ? '<h3 class="formSec">Latest documents</h3>' + UI.table(["Number", "Date", "Type", "Total", "Status"], d.recent.map(function (t) {
      return '<tr class="link" onclick="location.href=\'voucher-view.html?id=' + t.id + '\'"><td><b>' + esc(t.document_no || "Draft") + "</b></td><td>" + t.transaction_date + "</td><td>" + esc(C.TYPE_LABEL[t.transaction_type] || "") + '</td><td class="n">' + C.money(t.grand_total) + "</td><td>" + UI.tag(t.status) + "</td></tr>"; }), "No documents yet.") : "");
});
