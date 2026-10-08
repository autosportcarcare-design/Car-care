UI.cloudPage("records", async function (ctx, view) {
  var C = Cloud, esc = C.esc, id = C.query("id");
  var got = await DocRender.load(ctx, id), d = got.data, t = d.tx, p = d.party || {};
  var label = (C.TYPE_LABEL[t.transaction_type] || "Document") + " " + (t.document_no || "draft");
  var summary = label + " from " + (d.org.legal_name || d.org.operating_name || ctx.company.name) + " — total " + (t.currency || "AED") + " " + C.money(t.grand_total) +
    (t.due_date ? ", due " + t.due_date : "") + (d.vehicle && d.vehicle.plate_number ? ", vehicle " + d.vehicle.plate_number : "") + ".";
  var phone = String(p.whatsapp || p.mobile || "").replace(/[^\d]/g, ""); if (/^0\d{8,9}$/.test(phone)) phone = "971" + phone.slice(1);
  view.innerHTML = UI.head(label, t.status === "posted" ? "Printed from the frozen posted copy (layout, customer details and photos as posted)." : "Draft preview — the number is given when posted.",
      '<a class="btn" href="voucher-view.html?id=' + id + '">Back</a> <button class="btn pri" id="pr">Print</button> <button class="btn" id="pdf">Save as PDF</button> ' +
      '<button class="btn" id="sh">Share</button> <a class="btn" id="wa" target="_blank" rel="noopener">WhatsApp</a> <a class="btn" id="em">Email</a>') +
    '<div class="docWrap">' + DocRender.render(d, got.cfg) + "</div>";
  document.title = label;
  document.getElementById("pr").onclick = function () { window.print(); };
  document.getElementById("pdf").onclick = function () { UI.notify("Save as PDF", "In the print window choose “Save as PDF” (desktop) or pinch-out the preview and use Share → Save to Files (iPhone). The file is named " + label + ".pdf."); setTimeout(function () { window.print(); }, 300); };
  document.getElementById("wa").href = "https://wa.me/" + phone + "?text=" + encodeURIComponent(summary);
  document.getElementById("em").href = "mailto:" + encodeURIComponent(p.email || "") + "?subject=" + encodeURIComponent(label) + "&body=" + encodeURIComponent(summary + "\n\nThe PDF copy is attached.");
  document.getElementById("sh").onclick = async function () {
    if (navigator.share) { try { await navigator.share({ title: label, text: summary }); } catch (e) { } }
    else { try { await navigator.clipboard.writeText(summary); C.flash("Summary copied. Paste it into any app, then attach the PDF."); } catch (e) { C.flash(summary); } }
  };
});
