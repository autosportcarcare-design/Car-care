/* Cloud data layer — PostgreSQL (Supabase) is the source of truth.
   Every business write goes through a server function that checks permission
   and writes the audit trail. The page then READS THE RECORD BACK from the
   database and compares it with what was sent before it says "saved". */
(function (w) {
  var SUPABASE_URL = "https://pwzpljitxamthgqllgtu.supabase.co";
  var SUPABASE_KEY = "sb_publishable_kybFJ1asPgqHEDROCREbUA_XhQWYJqz"; // publishable key: safe in the browser, RLS protects data
  var AUTH_KEY = "bp.auth", COMPANY_KEY = "bp.company";

  var C = {};
  C.sb = w.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, storageKey: AUTH_KEY, detectSessionInUrl: true }
  });

  function pref(k, v) {
    try { if (v === undefined) return localStorage.getItem(k); if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v); }
    catch (e) { return null; }
  }
  /* Synchronous hint used only to gate the not-yet-migrated screens. */
  C.hasStoredSession = function () { return !!pref(AUTH_KEY); };

  C.esc = function (s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  };
  C.money = function (n) {
    return (Number(n) < 0 ? "-" : "") + Math.abs(Number(n) || 0).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  };
  C.date = function (d) { return d ? String(d).slice(0, 10) : ""; };
  C.when = function (d) { if (!d) return ""; var x = new Date(d); return x.toLocaleDateString("en-GB") + " " + x.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" }); };
  C.query = function (k) { return new URLSearchParams(location.search).get(k); };

  /* Turn database errors into something a person can act on. */
  C.message = function (err) {
    var m = (err && (err.message || err.error_description || err.msg)) || String(err || "Unknown error");
    if (/Failed to fetch|NetworkError|Load failed/i.test(m)) return "No connection to the server. Nothing was saved. Check the internet connection and try again.";
    if (/JWT|jwt expired|not authenticated|authentication required/i.test(m)) return "Your session has ended. Please sign in again.";
    if (/Invalid login credentials/i.test(m)) return "Email or password is incorrect.";
    if (/rate limit/i.test(m)) return "Too many emails were requested in the last hour, so the email service refused this one. Wait an hour and try again. (Your administrator can remove this limit by connecting a custom email/SMTP service in Supabase.)";
    if (/Email address .* is invalid/i.test(m)) return "That email address was refused. Please check it and try again.";
    if (/Email not confirmed/i.test(m)) return "This email is not confirmed yet. Open the confirmation link that was emailed to you, then sign in.";
    return m.replace(/^ERROR:\s*/, "");
  };

  C.rpc = async function (name, args) {
    var r = await C.sb.rpc(name, args || {});
    if (r.error) throw new Error(C.message(r.error));
    return r.data;
  };

  /* ---------------- auth ---------------- */
  C.user = async function () {
    var r = await C.sb.auth.getSession();
    return r.data && r.data.session ? r.data.session.user : null;
  };
  C.signIn = async function (email, password) {
    var r = await C.sb.auth.signInWithPassword({ email: email, password: password });
    if (r.error) throw new Error(C.message(r.error));
    return r.data.user;
  };
  C.signUp = async function (email, password) {
    var r = await C.sb.auth.signUp({ email: email, password: password,
      options: { emailRedirectTo: location.origin + location.pathname.replace(/[^/]*$/, "") + "login.html" } });
    if (r.error) throw new Error(C.message(r.error));
    return { user: r.data.user, needsConfirmation: !r.data.session };
  };
  C.resetPassword = async function (email) {
    var r = await C.sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname.replace(/[^/]*$/, "") + "login.html?mode=newpass" });
    if (r.error) throw new Error(C.message(r.error));
  };
  C.setNewPassword = async function (password) {
    var r = await C.sb.auth.updateUser({ password: password });
    if (r.error) throw new Error(C.message(r.error));
  };
  C.signOut = async function () {
    var id = pref(COMPANY_KEY);
    try { if (id) await C.rpc("log_session_event", { p_org: id, p_action: "auth.logout" }); } catch (e) {}
    await C.sb.auth.signOut();
    pref(COMPANY_KEY, null);
  };

  /* ---------------- company context ---------------- */
  C.ctx = null;
  C.companies = async function () { return (await C.rpc("my_organizations")) || []; };
  C.setCompany = async function (id, audit) {
    var prev = pref(COMPANY_KEY);
    pref(COMPANY_KEY, id);
    if (audit && prev && prev !== id) { try { await C.rpc("log_session_event", { p_org: id, p_action: "company.switch" }); } catch (e) {} }
  };
  /* Every cloud page starts here: signed in, member of at least one company. */
  C.require = async function () {
    var user = await C.user();
    if (!user) { location.replace("login.html?next=" + encodeURIComponent(location.pathname.split("/").pop() + location.search)); throw new Error("redirect"); }
    var list = await C.companies();
    if (!list.length) { location.replace("setup.html"); throw new Error("redirect"); }
    var id = pref(COMPANY_KEY);
    var company = list.filter(function (o) { return o.id === id; })[0] || list[0];
    pref(COMPANY_KEY, company.id);
    C.ctx = { user: user, company: company, companies: list, org: company.id, perms: company.permissions || [] };
    return C.ctx;
  };
  C.can = function (perm) { return !!(C.ctx && C.ctx.perms.indexOf(perm) >= 0); };

  /* ---------------- verified writes ----------------
     1. call the server function (it validates, checks permission, audits)
     2. read the same row back from the table by id
     3. compare every field that was sent
     Only a clean comparison counts as saved. */
  var NORMAL = {
    tax_registration_no: function (v) { return String(v || "").replace(/\s/g, ""); },
    plate_number: function (v) { return String(v || "").trim().toUpperCase(); },
    chassis_vin: function (v) { return String(v || "").trim().toUpperCase(); }
  };
  function same(key, sent, stored) {
    var norm = NORMAL[key] || function (v) { return v == null ? "" : String(v).trim(); };
    var a = norm(sent), b = norm(stored);
    if (a === "" && (stored == null || b === "" || (typeof stored === "number" && stored === 0) || b === "0")) return true;
    if (a !== "" && !isNaN(a) && b !== "" && !isNaN(b) && /^-?[\d.]+$/.test(a)) return Number(a) === Number(b);
    return a === b;
  }
  C.verifiedSave = async function (rpcName, args, table, sent, skip) {
    var saved = await C.rpc(rpcName, args);
    if (!saved || !saved.id) throw new Error("The server did not return a saved record. Nothing is confirmed.");
    var r = await C.sb.from(table).select("*").eq("id", saved.id).maybeSingle();
    if (r.error) throw new Error("Saved, but it could not be read back to confirm: " + C.message(r.error));
    if (!r.data) throw new Error("The record could not be found after saving. Treat it as NOT saved and try again.");
    var bad = Object.keys(sent || {}).filter(function (k) {
      return (skip || []).indexOf(k) < 0 && k in r.data && !same(k, sent[k], r.data[k]);
    });
    if (bad.length) throw new Error("The database copy does not match what was entered (" + bad.join(", ") + "). Please review before continuing.");
    return r.data;
  };

  /* ---------------- form helpers ---------------- */
  C.EMIRATES = ["Abu Dhabi", "Dubai", "Sharjah", "Ajman", "Umm Al Quwain", "Ras Al Khaimah", "Fujairah"];
  /* field: {k, label, type?, opts?, span?, hint?, req?, ph?} */
  C.fields = function (list, values) {
    values = values || {};
    return list.map(function (f) {
      if (f.section) return '<h3 class="formSec">' + C.esc(f.section) + "</h3>";
      var v = values[f.k] == null ? (f.def == null ? "" : f.def) : values[f.k];
      var id = "f_" + f.k, input;
      if (f.type === "select") {
        input = '<select id="' + id + '" name="' + f.k + '">' + f.opts.map(function (o) {
          var val = typeof o === "string" ? o : o.v, lab = typeof o === "string" ? o : o.l;
          return '<option value="' + C.esc(val) + '"' + (String(val) === String(v) ? " selected" : "") + ">" + C.esc(lab) + "</option>";
        }).join("") + "</select>";
      } else if (f.type === "textarea") {
        input = '<textarea id="' + id + '" name="' + f.k + '" rows="3">' + C.esc(v) + "</textarea>";
      } else {
        input = '<input id="' + id + '" name="' + f.k + '" type="' + (f.type || "text") + '" value="' + C.esc(v) + '"' +
          (f.ph ? ' placeholder="' + C.esc(f.ph) + '"' : "") + (f.list ? ' list="' + f.list + '"' : "") +
          (f.type === "number" ? ' step="any" inputmode="decimal"' : "") + (f.type === "tel" ? ' inputmode="tel"' : "") + ">";
      }
      return '<label class="field' + (f.span ? " span" + f.span : "") + '"><span>' + C.esc(f.label) + (f.req ? " *" : "") + "</span>" + input +
        (f.hint ? '<small class="hint">' + C.esc(f.hint) + "</small>" : "") + "</label>";
    }).join("");
  };
  C.collect = function (root) {
    var out = {};
    Array.prototype.forEach.call(root.querySelectorAll("[name]"), function (el) { out[el.name] = el.value.trim(); });
    return out;
  };


  /* ---------------- reference data (one load per page) ---------------- */
  C.uuid = function () { return (w.crypto && crypto.randomUUID) ? crypto.randomUUID() : "k" + Date.now() + Math.random().toString(16).slice(2); };
  C.today = function () { var d = new Date(); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 10); };
  C.monthStart = function () { return C.today().slice(0, 8) + "01"; };
  C.yearStart = function () { return C.today().slice(0, 5) + "01-01"; };
  async function q(p) { var r = await p; if (r.error) throw new Error(C.message(r.error)); return r.data; }
  C.q = q;
  C.masters = async function (ctx, parts) {
    parts = parts || ["settings", "companies", "branches", "warehouses", "tax", "pay", "products", "parties"];
    var org = ctx.org, M = {}, jobs = [];
    function add(k, p) { if (parts.indexOf(k) >= 0) jobs.push(q(p).then(function (d) { M[k] = d; })); }
    add("settings", C.sb.from("organization_settings").select("*").eq("organization_id", org).maybeSingle());
    add("companies", C.sb.from("companies").select("*").eq("organization_id", org).order("is_default", { ascending: false }));
    add("branches", C.sb.from("branches").select("*").eq("organization_id", org).order("is_default", { ascending: false }));
    add("warehouses", C.sb.from("warehouses").select("*").eq("organization_id", org).order("code"));
    add("tax", C.sb.from("tax_codes").select("*").eq("organization_id", org).order("code"));
    add("pay", C.sb.from("payment_methods").select("*").eq("organization_id", org).order("name"));
    add("products", C.sb.from("products").select("*").eq("organization_id", org).order("name").limit(5000));
    add("parties", C.sb.from("parties").select("id,party_code,display_name,name,party_type,status,mobile,whatsapp,email,tax_registration_no,credit_days,address,city,emirate").eq("organization_id", org).order("name").limit(5000));
    await Promise.all(jobs);
    M.settings = M.settings || {};
    M.company = (M.companies || [])[0] || null;
    M.activeTax = function (date) { return (M.tax || []).filter(function (t) { return t.status === "active" && t.effective_from <= date && (!t.effective_to || t.effective_to >= date); }); };
    return M;
  };
  C.partyName = function (p) { return p ? (p.display_name || p.name || "—") : "—"; };

  /* ---------------- private storage ---------------- */
  C.BUCKET = "business-media";
  /* Upload → insert metadata → read the row back → confirm the object exists. */
  C.upload = async function (ctx, file, meta) {
    var ext = (file.name && file.name.indexOf(".") > 0 ? file.name.split(".").pop() : (file.type.split("/")[1] || "bin")).toLowerCase().replace(/[^a-z0-9]/g, "").slice(0, 8);
    var path = ctx.org + "/" + (meta.folder || "files") + "/" + C.today().slice(0, 7) + "/" + C.uuid() + "." + ext;
    var up = await C.sb.storage.from(C.BUCKET).upload(path, file, { contentType: file.type || "application/octet-stream", upsert: false });
    if (up.error) throw new Error("Upload failed: " + C.message(up.error));
    var row = {
      organization_id: ctx.org, entity_type: meta.entity_type || "general", entity_id: meta.entity_id || null, category: meta.category || "SUPPORTING",
      storage_path: path, file_name: file.name || ("capture." + ext), mime_type: file.type || "application/octet-stream", size_bytes: file.size || 0,
      created_by: ctx.user.id, customer_id: meta.customer_id || null, vehicle_id: meta.vehicle_id || null,
      service_job_id: meta.service_job_id || null, transaction_id: meta.transaction_id || null, caption: meta.caption || null,
      metadata: { source: meta.source || "upload" }
    };
    var ins = await C.sb.from("attachments").insert(row).select("*").single();
    if (ins.error) { await C.sb.storage.from(C.BUCKET).remove([path]); throw new Error("File stored but its record failed, so it was removed: " + C.message(ins.error)); }
    var back = await C.sb.from("attachments").select("*").eq("id", ins.data.id).maybeSingle();
    var chk = await C.sb.storage.from(C.BUCKET).createSignedUrl(path, 60);
    if (back.error || !back.data || chk.error) throw new Error("The upload could not be confirmed from the database/storage.");
    return back.data;
  };
  C.signedUrls = async function (paths, secs) {
    if (!paths.length) return {};
    var r = await C.sb.storage.from(C.BUCKET).createSignedUrls(paths, secs || 3600);
    if (r.error) throw new Error(C.message(r.error));
    var out = {}; r.data.forEach(function (x) { if (x.signedUrl) out[x.path] = x.signedUrl; }); return out;
  };

  /* ---------------- amount in words (AED / fils) ---------------- */
  C.words = function (n, cur) {
    var ones = ["", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve", "Thirteen", "Fourteen", "Fifteen", "Sixteen", "Seventeen", "Eighteen", "Nineteen"];
    var tens = ["", "", "Twenty", "Thirty", "Forty", "Fifty", "Sixty", "Seventy", "Eighty", "Ninety"];
    function h(x) { var s = ""; if (x >= 100) { s += ones[Math.floor(x / 100)] + " Hundred"; x %= 100; if (x) s += " "; }
      if (x >= 20) { s += tens[Math.floor(x / 10)]; if (x % 10) s += "-" + ones[x % 10]; } else if (x) s += ones[x]; return s; }
    function whole(x) { if (!x) return "Zero"; var parts = [], units = ["", " Thousand", " Million", " Billion"], i = 0;
      while (x > 0) { var c = x % 1000; if (c) parts.unshift(h(c) + units[i]); x = Math.floor(x / 1000); i++; } return parts.join(" "); }
    n = Math.round(Math.abs(Number(n) || 0) * 100);
    var main = Math.floor(n / 100), fils = n % 100;
    return (cur === "AED" || !cur ? "UAE Dirhams " : cur + " ") + whole(main) + (fils ? " and " + whole(fils) + " Fils" : "") + " Only";
  };

  C.TYPE_LABEL = { sale: "Trading Invoice", service_sale: "Service Invoice", mixed_sale: "Tax Invoice", purchase: "Purchase Invoice", quotation: "Quotation",
    receipt: "Receipt Voucher", payment: "Payment Voucher", expense: "Expense Voucher", income: "Income Voucher", capital: "Capital", drawing: "Owner Withdrawal",
    credit_note: "Credit Note", debit_note: "Debit Note", customer_refund: "Customer Refund", supplier_refund: "Supplier Refund", purchase_order: "Purchase Order",
    delivery_note: "Delivery Note", journal: "Journal", contra: "Contra", stock_adjustment: "Stock Adjustment", transfer: "Stock Transfer", opening_balance: "Opening Balance" };
  /* ---------------- messages ---------------- */
  C.flash = function (text, kind) {
    var el = document.getElementById("flash");
    if (!el) { el = document.createElement("div"); el.id = "flash"; document.body.appendChild(el); }
    el.className = "flash " + (kind || "ok");
    el.textContent = text;
    el.style.display = "block";
    clearTimeout(C._ft);
    C._ft = setTimeout(function () { el.style.display = "none"; }, kind === "err" ? 9000 : 4500);
  };
  C.busy = function (btn, on, label) {
    if (!btn) return;
    if (on) { btn.dataset.label = btn.textContent; btn.textContent = label || "Saving…"; btn.disabled = true; }
    else { btn.textContent = btn.dataset.label || btn.textContent; btn.disabled = false; }
  };

  w.Cloud = C;
})(window);
