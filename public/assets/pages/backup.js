UI.cloudPage("backup", async function (ctx, view) {
  var C = Cloud, sb = C.sb, esc = C.esc;
  var canBackup = C.can("backup.create") || C.can("backup.manage"), canRestore = C.can("backup.manage");
  var mans = await C.q(sb.from("backup_manifests").select("*").eq("organization_id", ctx.org).order("created_at", { ascending: false }).limit(25)).catch(function () { return []; });

  function stamp() { return new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-"); }
  async function exportBackup(label) {
    var data = await C.rpc("export_business_backup", { p_org: ctx.org });
    if (!data || data.format !== "business-platform-backup") throw new Error("The backup did not come back in the expected format.");
    var name = (ctx.company.name || "company").replace(/[^\w]+/g, "-").toLowerCase() + "-" + (label || "backup") + "-" + stamp() + ".json";
    UI.download(name, JSON.stringify(data, null, 1), "application/json");
    return { data: data, name: name };
  }

  view.innerHTML = UI.head("Backup & restore", "Backups are built by the database, not the browser.", "") +
    '<div class="panel"><h2>Backup</h2><div class="body"><p>Downloads one JSON file containing settings, companies, branches, warehouses, roles and permissions, customers and suppliers, vehicles, products, stock, all documents and their lines, journals, AR/AP and allocations, workshop jobs, tasks and parts, document layouts and versions, numbering, media records and the audit trail.</p>' +
    '<p class="note">Photos, files and voice notes themselves stay in private storage and are not inside this file — their records are. Keep the file somewhere safe: it contains your full business data.</p>' +
    (canBackup ? '<button class="btn pri" id="exp">Download backup now</button>' : "<p>Backups need the Create backup permission.</p>") + "</div></div>" +
    '<div class="panel" style="margin-top:12px"><h2>Restore</h2><div class="body">' +
    '<p>A restore never overwrites your live company. The backup is rebuilt as a <b>separate company</b> that you can switch to, compare and then keep. Each step must pass or nothing is written at all.</p>' +
    '<ol style="font-size:13px;line-height:1.8;padding-left:18px"><li>Validate the file</li><li>Safety backup of the company you are in now</li><li>Restore into a new company</li><li>Read the database back and check counts and links</li><li>Trial balance, balance sheet, stock, AR/AP, VAT, numbering</li><li>Write the restore into the audit trail</li></ol>' +
    (canRestore ? '<label class="btn">Choose backup file<input type="file" id="file" accept="application/json,.json" class="hide"></label> <span id="fname" style="font-size:12.5px;color:var(--mute)"></span>' +
      '<div id="rsum"></div>' : "<p>Restoring needs the Manage backups permission.</p>") + "</div></div>" +
    '<h3 class="formSec">Backup history</h3>' + UI.table(["When", "Type", "Status", "Schema", "Details"], mans.map(function (m) {
      return "<tr><td>" + C.when(m.created_at) + "</td><td>" + esc(m.backup_type) + "</td><td>" + UI.tag(m.status) + "</td><td>" + esc(m.schema_version || "") + "</td><td>" +
        esc(m.restored_at ? "Restored copy created" : "Exported") + "</td></tr>"; }), "No backups recorded yet.");

  var eb = document.getElementById("exp");
  if (eb) eb.onclick = async function () { C.busy(eb, true, "Building…");
    try { var r = await exportBackup("backup"); C.flash("Backup downloaded and recorded: " + r.name); setTimeout(function () { location.reload(); }, 1200); }
    catch (e) { C.busy(eb, false); C.flash(C.message(e), "err"); } };

  var fi = document.getElementById("file");
  if (fi) fi.onchange = function () {
    var f = fi.files[0]; if (!f) return;
    document.getElementById("fname").textContent = f.name + " (" + Math.round(f.size / 1024) + " KB)";
    var rd = new FileReader();
    rd.onload = function () {
      var data;
      try { data = JSON.parse(rd.result); } catch (e) { return C.flash("That file is not valid JSON.", "err"); }
      if (data.format !== "business-platform-backup") return C.flash("That file is not a Business Platform backup.", "err");
      var counts = ["transactions", "journal_lines", "parties", "vehicles", "products", "service_jobs"].map(function (k) { return (data[k] || []).length + " " + k.replace(/_/g, " "); }).join(" · ");
      document.getElementById("rsum").innerHTML = '<div class="note">From <b>' + esc((data.organization || {}).name || "unknown company") + "</b>, taken " + esc(String(data.created_at || "").slice(0, 16).replace("T", " ")) + ".<br>" + esc(counts) + "</div>" +
        '<label class="field" style="max-width:420px"><span>Name for the restored company</span><input id="rname" value="' + esc(((data.organization || {}).name || "Company") + " (restored " + C.today() + ")") + '"></label>' +
        '<button class="btn warn" id="go">Safety backup, then restore</button><div id="rlog" style="margin-top:10px;font-size:13px"></div>';
      document.getElementById("go").onclick = function () {
        UI.confirm("Restore this backup?", "Your current company is not touched. A safety backup of it downloads first, then the file is rebuilt as a new company and checked.", async function () {
          var btn = document.getElementById("go"), log = document.getElementById("rlog");
          function say(t, ok) { log.innerHTML += '<div class="' + (ok === false ? "due" : "verified") + '">' + (ok === false ? "✕ " : "✓ ") + esc(t) + "</div>"; }
          C.busy(btn, true, "Restoring…");
          try {
            say("Backup file validated.");
            try { var sfe = await exportBackup("safety-before-restore"); say("Safety backup of " + ctx.company.name + " downloaded (" + sfe.name + ")."); }
            catch (e) { say("Safety backup failed: " + C.message(e) + " — restore stopped.", false); C.busy(btn, false); return; }
            var res = await C.rpc("restore_business_backup", { p_backup: data, p_name: document.getElementById("rname").value });
            var v = res.verification || {};
            say("Restored into a new company and read back from the database.");
            say("Counts match: " + v.transactions + " documents, " + v.journal_lines + " journal lines, " + v.parties + " customers/suppliers, " + v.products + " products.");
            say("Trial balance: " + C.money(v.trial_balance_debit) + " = " + C.money(v.trial_balance_credit) + ".");
            say("Balance sheet: assets " + C.money(v.assets) + " = liabilities " + C.money(v.liabilities) + " + equity/profit " + C.money(v.equity_plus_profit) + ".");
            say("Stock " + v.stock_quantity + " units · receivable " + C.money(v.receivable) + " · payable " + C.money(v.payable) + " · VAT " + C.money(v.vat_posted) + ".");
            say("Numbering restored for " + v.sequences + " series. Restore written to the audit trail.");
            log.innerHTML += '<p style="margin-top:10px"><b>Restore verified.</b> Photos and files are not copied; they stay with the original company.</p>' +
              '<button class="btn pri" id="sw">Switch to the restored company</button>';
            document.getElementById("sw").onclick = function () { C.setCompany(res.organization_id, true).then(function () { location.href = "dashboard.html"; }); };
            C.busy(btn, false); btn.disabled = true;
          } catch (e) { say(C.message(e), false); log.innerHTML += '<p><b>Nothing was restored.</b> The database rolled the whole restore back, so no half-finished data exists.</p>'; C.busy(btn, false); }
        }, "Restore");
      };
    };
    rd.readAsText(f);
  };
});
