UI.cloudPage("dashboard", async function (ctx, view) {
  var C = Cloud, esc = C.esc, q = C.query("q") || "";
  var gq = document.getElementById("gq"); if (gq) gq.value = q;
  var r = await C.rpc("global_search", { p_org: ctx.org, p_q: q });
  if (r.length === 1) { location.replace(r[0].url); return; }
  view.innerHTML = UI.head("Search", r.length + " result" + (r.length === 1 ? "" : "s") + " for “" + esc(q) + "”", "") +
    UI.table(["Type", "Record", "Details"], r.map(function (x) {
      return '<tr class="link" onclick="location.href=\'' + esc(x.url) + '\'"><td>' + esc(x.kind) + "</td><td><b>" + esc(x.title) + "</b></td><td>" + esc(x.sub || "") + "</td></tr>"; }),
      q.length < 2 ? "Type at least two characters." : "Nothing found. Try a phone number, TRN, plate, invoice number, SKU or amount.");
});
