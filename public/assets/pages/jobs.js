UI.cloudPage("jobs", async function (ctx, view) {
  var C = Cloud, sb = C.sb, esc = C.esc;
  var STATUS = ["draft", "open", "inspection", "waiting_customer", "in_progress", "waiting_parts", "completed", "invoiced", "delivered", "cancelled"];
  var CATS = ["service", "labour", "mechanical", "electrical", "paint", "body_repair", "polishing", "detailing", "ceramic", "ppf", "wrapping", "tinting", "interior", "outside_work", "additional_work", "inspection", "custom"];
  var PHOTO = ["BEFORE", "DURING", "AFTER", "DAMAGE", "INSPECTION", "DELIVERY", "SUPPORTING"];
  var M = await C.masters(ctx, ["companies", "parties", "products"]);
  var canManage = C.can("service.manage");
  function nice(s) { return String(s || "").replace(/_/g, " "); }
  function pname(id) { return C.partyName(M.parties.filter(function (p) { return p.id === id; })[0]); }

  async function list() {
    var f = C.query("status") || "active", q = (C.query("q") || "").toLowerCase();
    var rows = await C.q(sb.from("service_jobs").select("*").eq("organization_id", ctx.org).order("created_at", { ascending: false }).limit(1000));
    rows = rows.filter(function (j) { return f === "all" ? true : f === "active" ? ["delivered", "cancelled", "invoiced"].indexOf(j.status) < 0 : j.status === f; })
      .filter(function (j) { return !q || [j.job_no, j.plate_no, j.chassis_no, j.vehicle_make, j.vehicle_model, pname(j.customer_id), j.customer_phone].join(" ").toLowerCase().indexOf(q) >= 0; });
    view.innerHTML = UI.head("Job cards", "Customer → vehicle → inspection → photos → work → invoice.", canManage ? '<a class="btn pri" href="job-cards.html?new=1">+ Job card</a>' : "") +
      '<div class="pill">' + ["active"].concat(STATUS).concat(["all"]).map(function (s) { return '<a href="job-cards.html?status=' + s + '"' + (f === s ? ' class="on"' : "") + ">" + nice(s) + "</a>"; }).join("") + "</div>" +
      '<input id="jq" class="searchBox" type="search" aria-label="Search job cards" placeholder="Search job no., plate, chassis, customer, phone" value="' + esc(q) + '" style="margin-bottom:12px">' +
      UI.table(["Job", "Opened", "Customer", "Vehicle", "Promised", "Status"], rows.map(function (j) {
        return '<tr class="link" onclick="location.href=\'job-cards.html?id=' + j.id + '\'"><td><b>' + esc(j.job_no) + "</b></td><td>" + C.date(j.opened_date) + "</td><td>" + esc(pname(j.customer_id)) + "</td><td>" +
          esc([j.plate_no, j.vehicle_make, j.vehicle_model].filter(Boolean).join(" ")) + "</td><td>" + C.date(j.promised_date) + "</td><td>" + UI.tag(j.status) + "</td></tr>"; }), "No job cards here.");
    var jq = document.getElementById("jq"); jq.onchange = function () { location.href = "job-cards.html?status=" + f + "&q=" + encodeURIComponent(jq.value); };
  }

  async function create() {
    var cust = M.parties.filter(function (p) { return p.status !== "archived" && p.party_type !== "supplier"; }), sel = C.query("customer") || "";
    view.innerHTML = UI.head("New job card", "The job number is allocated by the database when it is saved.", "") +
      '<div class="panel"><form id="jf" class="body form">' +
      '<label class="field span2"><span>Customer *</span><select id="j_c"><option value="">Choose…</option>' + cust.map(function (p) { return '<option value="' + p.id + '"' + (p.id === sel ? " selected" : "") + ">" + esc(C.partyName(p) + (p.mobile ? " · " + p.mobile : "")) + "</option>"; }).join("") + "</select></label>" +
      '<label class="field span2"><span>Vehicle *</span><select id="j_v"><option value="">Choose the customer first</option></select></label>' +
      '<label class="field"><span>Mileage (km)</span><input id="j_m" type="number" inputmode="numeric"></label><label class="field"><span>Promised date</span><input id="j_p" type="date"></label>' +
      '<label class="field span4"><span>Customer complaint</span><textarea id="j_cp" rows="2"></textarea></label>' +
      '<label class="field span4"><span>Requested work</span><textarea id="j_rw" rows="2" placeholder="e.g. Full-body PPF, ceramic coating, 30% tint"></textarea></label>' +
      '<div style="grid-column:1/-1;display:flex;gap:8px;justify-content:flex-end"><a class="btn" href="job-cards.html">Cancel</a><a class="btn" id="newVeh" href="vehicles.html?new=1">+ Vehicle</a><button class="btn pri" id="j_go" type="submit">Open job card</button></div></form></div>';
    async function vehs() {
      var c = document.getElementById("j_c").value, vs = c ? await C.q(sb.from("vehicles").select("*").eq("organization_id", ctx.org).eq("customer_id", c).eq("status", "active")) : [];
      document.getElementById("j_v").innerHTML = vs.length ? vs.map(function (v) { return '<option value="' + v.id + '" data-m="' + (v.mileage || "") + '">' + esc([v.plate_number, v.make, v.model, v.year].filter(Boolean).join(" ")) + "</option>"; }).join("") : '<option value="">No vehicles — add one</option>';
      document.getElementById("newVeh").href = "vehicles.html?new=1" + (c ? "&customer=" + c : "");
      var o = document.getElementById("j_v").selectedOptions[0]; if (o && o.dataset.m) document.getElementById("j_m").placeholder = "Last: " + o.dataset.m;
    }
    document.getElementById("j_c").onchange = vehs; if (sel) vehs();
    document.getElementById("jf").onsubmit = async function (e) {
      e.preventDefault(); var b = document.getElementById("j_go"), c = document.getElementById("j_c").value, v = document.getElementById("j_v").value;
      if (!c || !v) return C.flash("Choose the customer and the vehicle.", "err");
      C.busy(b, true);
      try {
        var j = await C.rpc("create_service_job_v2", { p_org: ctx.org, p_company: M.company.id, p_branch: null, p_customer: c, p_vehicle: v,
          p_data: { mileage: document.getElementById("j_m").value, promised_date: document.getElementById("j_p").value, complaint: document.getElementById("j_cp").value, requested_work: document.getElementById("j_rw").value } });
        var back = await C.q(sb.from("service_jobs").select("id,job_no").eq("id", j.service_job_id || j.id).single());
        sessionStorage.setItem("bp.flash", "Job card " + back.job_no + " opened and verified."); location.replace("job-cards.html?id=" + back.id);
      } catch (err) { C.busy(b, false); C.flash(C.message(err), "err"); }
    };
  }

  async function detail(id) {
    var fl = sessionStorage.getItem("bp.flash"); if (fl) { sessionStorage.removeItem("bp.flash"); setTimeout(function () { C.flash(fl); }, 50); }
    var j = await C.q(sb.from("service_jobs").select("*").eq("id", id).eq("organization_id", ctx.org).maybeSingle());
    if (!j) { view.innerHTML = '<div class="panel"><div class="empty">Job card not found.</div></div>'; return; }
    var r = await Promise.all([
      C.q(sb.from("service_job_tasks").select("*").eq("service_job_id", id).order("line_no")),
      C.q(sb.from("service_job_items").select("*").eq("service_job_id", id).order("created_at")),
      C.q(sb.from("attachments").select("*").eq("service_job_id", id).is("deleted_at", null).order("created_at")),
      C.q(sb.from("service_job_status_history").select("*").eq("service_job_id", id).order("changed_at")).catch(function () { return []; }),
      C.q(sb.from("transactions").select("id,document_no,transaction_type,status,grand_total,transaction_date").eq("service_job_id", id).order("created_at")).catch(function () { return []; })
    ]);
    var tasks = r[0], items = r[1], files = r[2], hist = r[3], docs = r[4];
    var urls = await C.signedUrls(files.map(function (f) { return f.storage_path; }), 3600).catch(function () { return {}; });
    var locked = ["delivered", "cancelled"].indexOf(j.status) >= 0, edit = canManage && !locked;
    var sale = tasks.reduce(function (a, t) { return a + Number(t.sale_price || t.estimated_amount || 0); }, 0) + items.reduce(function (a, i) { return a + Number(i.quantity) * Number(i.unit_price); }, 0);
    var cost = tasks.reduce(function (a, t) { return a + Number(t.actual_cost || 0); }, 0) + items.reduce(function (a, i) { return a + Number(i.quantity) * Number(i.unit_cost || 0); }, 0);
    var tab = C.query("tab") || "work";

    view.innerHTML = UI.head(j.job_no + " · " + [j.plate_no, j.vehicle_make, j.vehicle_model].filter(Boolean).join(" "),
      '<a href="parties.html?id=' + j.customer_id + '">' + esc(pname(j.customer_id)) + "</a>" + (j.customer_phone ? " · " + esc(j.customer_phone) : "") + " · opened " + C.date(j.opened_date) + (j.promised_date ? " · promised " + C.date(j.promised_date) : ""),
      '<a class="btn" href="job-cards.html">Jobs</a> ' + (edit ? '<a class="btn" href="new-transaction.html?type=quotation&job=' + id + '">Quotation</a> <a class="btn pri" href="new-transaction.html?type=service_sale&job=' + id + '">Service invoice</a>' : "")) +
      '<div class="rowTools"><label class="field"><span>Status</span><select id="st"' + (canManage && !locked ? "" : " disabled") + ">" + STATUS.map(function (s) { return '<option value="' + s + '"' + (s === j.status ? " selected" : "") + ">" + nice(s) + "</option>"; }).join("") + "</select></label>" +
        (C.can("profit.view") ? UI.stat("Estimated sale", C.money(sale)) + UI.stat("Cost", C.money(cost)) + UI.stat("Profit", C.money(sale - cost), sale ? Math.round((sale - cost) / sale * 100) + "%" : "") : "") + "</div>" +
      '<div class="tabs">' + [["work", "Work & inspection"], ["photos", "Photos & files (" + files.length + ")"], ["docs", "Quotations & invoices (" + docs.length + ")"], ["history", "History"]]
        .map(function (t) { return '<button data-t="' + t[0] + '"' + (tab === t[0] ? ' class="on"' : "") + ">" + t[1] + "</button>"; }).join("") + '</div><div id="pane"></div>';
    view.querySelectorAll("[data-t]").forEach(function (b) { b.onclick = function () { history.replaceState(null, "", "job-cards.html?id=" + id + "&tab=" + b.dataset.t); detail(id); }; });
    document.getElementById("st").onchange = function () {
      var to = this.value, el = this;
      UI.dialog({ title: "Change status to " + nice(to) + "?", input: "", placeholder: "Note (optional)", okLabel: "Change", onOk: async function (note) {
        try { await C.rpc("set_service_job_status", { p_org: ctx.org, p_job: id, p_status: to, p_note: note || "" });
          var b = await C.q(sb.from("service_jobs").select("status").eq("id", id).single()); if (b.status !== to) throw new Error("Status could not be confirmed.");
          sessionStorage.setItem("bp.flash", "Status saved and verified: " + nice(to)); detail(id);
        } catch (e) { el.value = j.status; C.flash(C.message(e), "err"); } } });
      document.getElementById("dlgNo").onclick = function () { UI.closeDialog(); el.value = j.status; };
    };
    var pane = document.getElementById("pane");

    if (tab === "work") {
      pane.innerHTML = '<div class="panel"><h2>Inspection and work</h2><form id="wf" class="body form">' +
        C.fields([{ k: "mileage", label: "Mileage (km)", type: "number" }, { k: "promised_date", label: "Promised date", type: "date" },
          { k: "complaint", label: "Customer complaint", type: "textarea", span: 4 }, { k: "inspection_notes", label: "Inspection findings", type: "textarea", span: 4 },
          { k: "requested_work", label: "Requested work", type: "textarea", span: 4 }, { k: "completed_work", label: "Completed work", type: "textarea", span: 4 }, { k: "notes", label: "Internal notes", type: "textarea", span: 4 }], j) +
        (edit ? '<div style="grid-column:1/-1;text-align:right"><button class="btn pri" id="wsave" type="submit">Save job card</button></div>' : "") + "</form></div>" +
        '<h3 class="formSec">Tasks — labour, services, outside work</h3>' +
        UI.table(["#", "Category", "Description", "Estimate", "Sale price", "Actual cost", "Status", ""], tasks.map(function (t) {
          return "<tr><td>" + t.line_no + "</td><td>" + nice(t.category || t.task_type) + "</td><td>" + esc(t.description) + '</td><td class="n">' + C.money(t.estimated_amount) + '</td><td class="n">' + C.money(t.sale_price) +
            '</td><td class="n">' + C.money(t.actual_cost) + "</td><td>" + (edit ? '<select data-ts="' + t.id + '">' + ["pending", "in_progress", "completed", "cancelled"].map(function (s) { return "<option" + (s === t.status ? " selected" : "") + ">" + s + "</option>"; }).join("") + "</select>" : nice(t.status)) +
            "</td><td>" + (edit ? '<button class="btn sm" data-td="' + t.id + '">✕</button>' : "") + "</td></tr>"; }), "No tasks yet.") +
        (edit ? '<div class="panel" style="margin-top:8px"><form id="tf" class="body form"><label class="field"><span>Category</span><select id="t_c">' + CATS.map(function (c) { return '<option value="' + c + '">' + nice(c) + "</option>"; }).join("") + "</select></label>" +
          '<label class="field span2"><span>Description *</span><input id="t_d" required></label><label class="field"><span>Assigned / notes</span><input id="t_n"></label>' +
          '<label class="field"><span>Estimate</span><input id="t_e" type="number" step="0.01"></label><label class="field"><span>Sale price</span><input id="t_s" type="number" step="0.01"></label>' +
          '<label class="field"><span>Actual cost (outside work, labour)</span><input id="t_a" type="number" step="0.01"></label><div class="field" style="align-self:end"><button class="btn" type="submit" style="width:100%">+ Add task</button></div></form></div>' : "") +
        '<h3 class="formSec">Parts and materials</h3>' +
        UI.table(["Item", "Description", "Qty", "Price", "Unit cost", "Total", ""], items.map(function (i) {
          return "<tr><td>" + esc((M.products.filter(function (p) { return p.id === i.product_id; })[0] || {}).sku || "—") + "</td><td>" + esc(i.description) + '</td><td class="n">' + Number(i.quantity) + '</td><td class="n">' + C.money(i.unit_price) +
            '</td><td class="n">' + C.money(i.unit_cost) + '</td><td class="n">' + C.money(i.quantity * i.unit_price) + "</td><td>" + (edit ? '<button class="btn sm" data-id2="' + i.id + '">✕</button>' : "") + "</td></tr>"; }), "No parts yet. Stock is issued when the service invoice is posted.") +
        (edit ? '<div class="panel" style="margin-top:8px"><form id="pf" class="body form"><label class="field span2"><span>Part / material</span><select id="p_p"><option value="">Free text</option>' +
          M.products.filter(function (p) { return p.status === "active" && ["inventory", "non_inventory", "package", "outside_work"].indexOf(p.item_type) >= 0; }).map(function (p) { return '<option value="' + p.id + '">' + esc((p.sku ? p.sku + " · " : "") + p.name) + "</option>"; }).join("") +
          '</select></label><label class="field span2"><span>Description *</span><input id="p_d"></label><label class="field"><span>Qty</span><input id="p_q" type="number" step="any" value="1"></label>' +
          '<label class="field"><span>Price</span><input id="p_u" type="number" step="0.01"></label><label class="field"><span>Unit cost</span><input id="p_c" type="number" step="0.01"></label>' +
          '<div class="field" style="align-self:end"><button class="btn" type="submit" style="width:100%">+ Add part</button></div></form></div>' : "");
      var wf = document.getElementById("wf");
      if (edit) wf.onsubmit = async function (e) {
        e.preventDefault(); var b = document.getElementById("wsave"), d = C.collect(wf); C.busy(b, true);
        try { await C.rpc("update_service_job", { p_org: ctx.org, p_job: id, p_data: d });
          var back = await C.q(sb.from("service_jobs").select("*").eq("id", id).single());
          if ((back.inspection_notes || "") !== (d.inspection_notes || "") || (back.complaint || "") !== (d.complaint || "")) throw new Error("The job card could not be confirmed.");
          sessionStorage.setItem("bp.flash", "Job card saved and verified."); detail(id);
        } catch (err) { C.busy(b, false); C.flash(C.message(err), "err"); }
      };
      var tf = document.getElementById("tf");
      if (tf) tf.onsubmit = async function (e) {
        e.preventDefault(); var cat = document.getElementById("t_c").value;
        try { var t = await C.rpc("add_service_job_task_v2", { p_org: ctx.org, p_company: j.company_id, p_job: id, p_data: { task_type: cat === "outside_work" ? "outside_work" : cat === "inspection" ? "inspection" : cat === "labour" ? "labour" : cat === "additional_work" ? "additional" : "service",
            category: cat, description: document.getElementById("t_d").value, estimated_amount: document.getElementById("t_e").value, sale_price: document.getElementById("t_s").value || document.getElementById("t_e").value,
            actual_cost: document.getElementById("t_a").value, notes: document.getElementById("t_n").value } });
          if (!t.verified) throw new Error("Task could not be confirmed.");
          sessionStorage.setItem("bp.flash", "Task added and verified."); detail(id);
        } catch (err) { C.flash(C.message(err), "err"); }
      };
      pane.querySelectorAll("[data-ts]").forEach(function (s) { s.onchange = async function () {
        try { await C.q(sb.from("service_job_tasks").update({ status: s.value }).eq("id", s.dataset.ts).select("id").single()); C.flash("Task status saved."); } catch (err) { C.flash(C.message(err), "err"); } }; });
      pane.querySelectorAll("[data-td]").forEach(function (b) { b.onclick = function () { UI.confirm("Remove this task?", "", async function () {
        try { await C.rpc("delete_service_task", { p_org: ctx.org, p_task: b.dataset.td }); detail(id); } catch (err) { C.flash(C.message(err), "err"); } }, "Remove"); }; });
      var pp = document.getElementById("p_p"); if (pp) pp.onchange = function () { var p = M.products.filter(function (x) { return x.id === pp.value; })[0];
        if (p) { document.getElementById("p_d").value = p.name; document.getElementById("p_u").value = p.sale_price; document.getElementById("p_c").value = p.average_cost || p.purchase_price || 0; } };
      var pf = document.getElementById("pf");
      if (pf) pf.onsubmit = async function (e) {
        e.preventDefault(); var d = document.getElementById("p_d").value.trim(), q = Number(document.getElementById("p_q").value);
        if (!d || !(q > 0)) return C.flash("Enter a description and a quantity.", "err");
        var prod = M.products.filter(function (x) { return x.id === pp.value; })[0];
        try { var ins = await C.q(sb.from("service_job_items").insert({ organization_id: ctx.org, company_id: j.company_id, service_job_id: id, product_id: pp.value || null, item_type: prod ? prod.item_type : "non_inventory",
            description: d, quantity: q, unit_price: Number(document.getElementById("p_u").value) || 0, unit_cost: Number(document.getElementById("p_c").value) || 0, created_by: ctx.user.id }).select("id").single());
          var back = await C.q(sb.from("service_job_items").select("id").eq("id", ins.id).maybeSingle()); if (!back) throw new Error("Part could not be confirmed.");
          sessionStorage.setItem("bp.flash", "Part added and verified."); detail(id);
        } catch (err) { C.flash(C.message(err), "err"); }
      };
      pane.querySelectorAll("[data-id2]").forEach(function (b) { b.onclick = async function () { try { await C.q(sb.from("service_job_items").delete().eq("id", b.dataset.id2)); detail(id); } catch (err) { C.flash("This part could not be removed: " + C.message(err), "err"); } }; });
    }

    if (tab === "photos") {
      pane.innerHTML = (edit || canManage ? '<div class="panel"><div class="body form">' +
        '<label class="field"><span>Category</span><select id="u_cat">' + PHOTO.map(function (c) { return "<option>" + c + "</option>"; }).join("") + "</select></label>" +
        '<label class="field span2"><span>Caption</span><input id="u_cap" placeholder="e.g. Scratch on rear bumper"></label><div></div>' +
        '<label class="btn" style="text-align:center">Camera<input id="u_cam" type="file" accept="image/*" capture="environment" class="hide"></label>' +
        '<label class="btn" style="text-align:center">Photo library<input id="u_gal" type="file" accept="image/*,video/*" multiple class="hide"></label>' +
        '<label class="btn" style="text-align:center">Files / PDF<input id="u_file" type="file" accept="image/*,video/*,application/pdf,audio/*" multiple class="hide"></label>' +
        '<button class="btn" id="u_voice" type="button">Record voice note</button>' +
        '<p id="u_msg" style="grid-column:1/-1;font-size:12px;color:var(--mute);margin:4px 0 0">Files are stored privately; links expire after one hour.</p></div></div>' : "") +
        PHOTO.map(function (c) {
          var fs = files.filter(function (f) { return (f.category || "SUPPORTING") === c; }); if (!fs.length) return "";
          return '<h3 class="formSec">' + c.charAt(0) + c.slice(1).toLowerCase() + " (" + fs.length + ')</h3><div class="panel"><div class="photoGrid">' + fs.map(function (f) {
            var u = urls[f.storage_path] || "", mt = f.mime_type || "";
            var inner = /^image\//.test(mt) ? '<a href="' + esc(u) + '" target="_blank" rel="noopener"><img src="' + esc(u) + '" alt="' + esc(f.caption || c) + '" loading="lazy"></a>' :
              /^video\//.test(mt) ? '<video src="' + esc(u) + '" controls preload="metadata"></video>' : /^audio\//.test(mt) ? '<div style="padding:30px 6px"><audio src="' + esc(u) + '" controls style="width:100%"></audio></div>' :
              '<a href="' + esc(u) + '" target="_blank" rel="noopener" style="display:block;padding:40px 8px;text-align:center">' + esc(f.file_name) + "</a>";
            return "<figure>" + inner + "<figcaption><span>" + esc(f.caption || C.date(f.created_at)) + "</span>" + (canManage ? '<button class="btn sm" data-del="' + f.id + '" title="Delete">✕</button>' : "") + "</figcaption></figure>"; }).join("") + "</div></div>";
        }).join("") + (files.length ? "" : '<div class="panel"><div class="empty">No photos or files yet. Add before photos when the car arrives.</div></div>');
      async function send(list, source) {
        var msg = document.getElementById("u_msg"), cat = document.getElementById("u_cat").value, cap = document.getElementById("u_cap").value, ok = 0;
        for (var i = 0; i < list.length; i++) {
          msg.textContent = "Uploading " + (i + 1) + " of " + list.length + "…";
          try { await C.upload(ctx, list[i], { folder: "jobs/" + id, entity_type: "service_job", entity_id: id, category: cat, caption: cap, service_job_id: id, customer_id: j.customer_id, vehicle_id: j.vehicle_id, source: source }); ok++; }
          catch (e) { C.flash(list[i].name + ": " + C.message(e), "err"); }
        }
        sessionStorage.setItem("bp.flash", ok + " file" + (ok === 1 ? "" : "s") + " uploaded and verified in private storage."); detail(id);
      }
      ["u_cam", "u_gal", "u_file"].forEach(function (k) { var el = document.getElementById(k); if (el) el.onchange = function () { if (el.files.length) send(Array.prototype.slice.call(el.files), k.slice(2)); }; });
      var vb = document.getElementById("u_voice"), rec = null, chunks = [];
      if (vb) vb.onclick = async function () {
        if (rec && rec.state === "recording") { rec.stop(); return; }
        if (!navigator.mediaDevices || !w.MediaRecorder) return C.flash("Voice recording is not supported in this browser. Use Files to upload an audio file.", "err");
        try {
          var stream = await navigator.mediaDevices.getUserMedia({ audio: true }); chunks = [];
          rec = new MediaRecorder(stream); rec.ondataavailable = function (e) { chunks.push(e.data); };
          rec.onstop = function () { stream.getTracks().forEach(function (t) { t.stop(); }); var type = rec.mimeType || "audio/webm";
            var f = new File(chunks, "voice-note-" + Date.now() + (/mp4/.test(type) ? ".m4a" : ".webm"), { type: type }); vb.textContent = "Record voice note"; send([f], "voice"); };
          rec.start(); vb.textContent = "■ Stop recording";
        } catch (e) { C.flash("Microphone not available: " + C.message(e), "err"); }
      };
      pane.querySelectorAll("[data-del]").forEach(function (b) { b.onclick = function () { UI.confirm("Delete this file?", "Files already on a posted invoice cannot be deleted.", async function () {
        try { await C.rpc("delete_attachment", { p_org: ctx.org, p_id: b.dataset.del }); sessionStorage.setItem("bp.flash", "File removed."); detail(id); } catch (e) { C.flash(C.message(e), "err"); } }, "Delete"); }; });
    }

    if (tab === "docs") {
      pane.innerHTML = UI.table(["Number", "Date", "Type", "Total", "Status"], docs.map(function (t) {
        return '<tr class="link" onclick="location.href=\'voucher-view.html?id=' + t.id + '\'"><td><b>' + esc(t.document_no || "Draft") + "</b></td><td>" + t.transaction_date + "</td><td>" + esc(C.TYPE_LABEL[t.transaction_type] || "") + '</td><td class="n">' + C.money(t.grand_total) + "</td><td>" + UI.tag(t.status) + "</td></tr>"; }),
        "No quotation or invoice yet. Use the buttons at the top.");
    }
    if (tab === "history") {
      pane.innerHTML = UI.table(["When", "From", "To", "Note"], hist.map(function (h) { return "<tr><td>" + C.when(h.changed_at) + "</td><td>" + nice(h.from_status || "—") + "</td><td>" + nice(h.to_status) + "</td><td>" + esc(h.note || "") + "</td></tr>"; }), "No status changes recorded.");
    }
  }
  var w = window;
  if (C.query("new")) { if (!canManage) { C.flash("You do not have the service permission.", "err"); return list(); } return create(); }
  if (C.query("id")) return detail(C.query("id"));
  list();
});
