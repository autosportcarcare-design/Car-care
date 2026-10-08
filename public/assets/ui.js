/* App shell — cloud only. PostgreSQL (Supabase) is the only business database.
   The browser keeps just the login session, the chosen company id and the theme. */
(function (w) {
  var C = w.Cloud, UI = {};
  var esc = C.esc;

  UI.NAV = [
    { id: "dashboard", label: "Dashboard", short: "Home", group: "Work", file: "dashboard.html" },
    { id: "new", label: "New transaction", short: "New", group: "Work", file: "new-transaction.html" },
    { id: "records", label: "Day book", short: "Records", group: "Work", file: "day-book.html" },
    { id: "jobs", label: "Job cards", short: "Jobs", group: "Work", file: "job-cards.html" },
    { id: "parties", label: "Customers & suppliers", short: "Parties", group: "Masters", file: "parties.html" },
    { id: "vehicles", label: "Vehicles", short: "Vehicles", group: "Masters", file: "vehicles.html" },
    { id: "stock", label: "Products & stock", short: "Stock", group: "Masters", file: "stock.html" },
    { id: "reports", label: "Reports", short: "Reports", group: "Finance", file: "reports.html" },
    { id: "designer", label: "Document designer", short: "Designer", group: "Finance", file: "document-designer.html" },
    { id: "users", label: "Users & roles", short: "Users", group: "Administration", file: "users.html" },
    { id: "settings", label: "Settings", short: "Settings", group: "Administration", file: "settings.html" },
    { id: "backup", label: "Backup & restore", short: "Backup", group: "Administration", file: "backup.html" }
  ];
  UI.QUICK = [["Customer", "parties.html?new=customer"], ["Vehicle", "vehicles.html?new=1"], ["Sale", "new-transaction.html?type=sale"],
    ["Purchase", "new-transaction.html?type=purchase"], ["Expense", "new-transaction.html?type=expense"], ["Receipt", "new-transaction.html?type=receipt"],
    ["Payment", "new-transaction.html?type=payment"], ["Service job", "job-cards.html?new=1"], ["Quotation", "new-transaction.html?type=quotation"],
    ["Invoice", "new-transaction.html?type=service_sale"]];

  /* ---------------- theme ---------------- */
  try { var th = localStorage.getItem("bp.theme"); if (th) document.documentElement.setAttribute("data-theme", th); } catch (e) {}
  UI.toggleTheme = function () {
    var next = document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    try { localStorage.setItem("bp.theme", next); } catch (e) {}
  };

  /* ---------------- shell ---------------- */
  UI.cloudPage = function (pageId, render) {
    C.require().then(function (ctx) {
      var nav = "", last = "";
      UI.NAV.forEach(function (p) {
        if (p.group !== last) { nav += '<div class="railGroup">' + p.group + "</div>"; last = p.group; }
        nav += '<a href="' + p.file + '"' + (p.id === pageId ? ' class="on" aria-current="page"' : "") + ">" + p.label + "</a>";
      });
      var bar = ["dashboard", "new", "jobs", "parties", "records", "reports"].map(function (id) {
        var p = UI.NAV.filter(function (x) { return x.id === id; })[0];
        return '<a href="' + p.file + '"' + (p.id === pageId ? ' class="on" aria-current="page"' : "") + ">" + p.short + "</a>";
      }).join("");
      var sw = ctx.companies.length > 1 ? '<select id="coSel" class="coSel" aria-label="Switch company">' + ctx.companies.map(function (c) {
        return '<option value="' + c.id + '"' + (c.id === ctx.org ? " selected" : "") + ">" + esc(c.name) + "</option>"; }).join("") + "</select>" : "";
      document.getElementById("app").innerHTML =
        '<a class="skip" href="#view">Skip to content</a>' +
        '<div class="shell"><aside class="rail"><div class="mark"><b>' + esc(ctx.company.name) + '</b><small>Business Platform</small></div><nav aria-label="Main">' + nav + "</nav></aside>" +
        '<main class="main"><div class="top">' +
          '<form class="gsearch" id="gs" role="search"><input id="gq" type="search" aria-label="Search all records" placeholder="Search customer, phone, TRN, plate, invoice, SKU, amount…" autocomplete="off"></form>' +
          '<div class="tools">' + sw + '<button class="btn sm" id="qaBtn" aria-expanded="false" aria-controls="qa">+ Quick</button>' +
            '<span class="who" title="' + esc(ctx.user.email) + '">' + esc(ctx.company.role) + "</span>" +
            '<a class="btn sm" href="setup.html">Companies</a><button class="btn sm" id="themeBtn">Theme</button><button class="btn sm" id="outBtn">Sign out</button></div></div>' +
          '<nav class="qa hide" id="qa" aria-label="Quick actions">' + UI.QUICK.map(function (q) { return '<a class="btn sm" href="' + q[1] + '">+ ' + q[0] + "</a>"; }).join("") + "</nav>" +
          '<div class="content" id="view" tabindex="-1"><div class="empty" role="status">Loading from the database…</div></div></main></div>' +
        '<nav class="bar" aria-label="Main (mobile)">' + bar + "</nav>";
      document.getElementById("themeBtn").onclick = UI.toggleTheme;
      document.getElementById("outBtn").onclick = function () { location.href = "login.html?logout=1"; };
      var qaBtn = document.getElementById("qaBtn"), qa = document.getElementById("qa");
      qaBtn.onclick = function () { var open = qa.classList.toggle("hide") === false; qaBtn.setAttribute("aria-expanded", String(open)); if (open) { var f = qa.querySelector("a"); if (f) f.focus(); } };
      qa.onkeydown = function (e) { if (e.key === "Escape") { qa.classList.add("hide"); qaBtn.setAttribute("aria-expanded", "false"); qaBtn.focus(); } };
      document.getElementById("gs").onsubmit = function (e) { e.preventDefault(); var q = document.getElementById("gq").value.trim(); if (q) location.href = "search.html?q=" + encodeURIComponent(q); };
      var sel = document.getElementById("coSel");
      if (sel) sel.onchange = function () { C.setCompany(sel.value, true).then(function () { location.reload(); }); };
      render(ctx, document.getElementById("view"));
      UI.watchLabels(document.getElementById("app"));
    }).catch(function (e) {
      if (e && e.message === "redirect") return;
      document.getElementById("app").innerHTML = '<div class="gate"><div class="gateCard"><h1>Could not load</h1><p class="sub">' +
        esc(C.message(e)) + '</p><button class="btn pri" onclick="location.reload()">Try again</button></div></div>';
    });
  };

  /* ---------------- view helpers ---------------- */
  UI.head = function (title, sub, tools) {
    return '<div class="head"><div><h1>' + esc(title) + "</h1>" + (sub ? "<p>" + sub + "</p>" : "") + '</div><div class="tools">' + (tools || "") + "</div></div>";
  };
  UI.stat = function (label, value, note, flag) {
    return '<div class="stat' + (flag ? " flag" : "") + '"><span>' + label + "</span><strong>" + value + "</strong>" + (note ? "<em>" + note + "</em>" : "") + "</div>";
  };
  UI.tag = function (status) { return '<span class="tag t-' + esc(status) + '">' + esc(String(status).replace(/_/g, " ")) + "</span>"; };
  UI.table = function (head, rows, empty, numeric) {
    numeric = numeric || /Total|Balance|Amount|Debit|Credit|Qty|Quantity|Value|Cost|Price|Net|VAT|Tax|Profit|Revenue|Outstanding|Paid|Margin|Days|Opening|Closing|Mileage|Rate/;
    return '<div class="panel">' + (rows.length ? '<div class="scroll"><table><thead><tr>' + head.map(function (h) {
      return "<th" + (numeric.test(h) ? ' class="n"' : "") + ">" + h + "</th>"; }).join("") + "</tr></thead><tbody>" + rows.join("") + "</tbody></table></div>"
      : '<div class="empty">' + (empty || "Nothing here yet.") + "</div>") + "</div>";
  };
  UI.kv = function (pairs) {
    return '<div class="kv">' + pairs.map(function (x) { return "<div><span>" + x[0] + "</span><b>" + (x[1] === "" || x[1] == null ? "—" : x[2] ? x[1] : esc(x[1])) + "</b></div>"; }).join("") + "</div>";
  };

  /* ---------------- dialogs (native confirm/prompt are blocked in some frames) ---------------- */
  var lastFocus = null;
  function closeDialog() {
    var d = document.getElementById("mbpDialog"); if (d) d.parentNode.removeChild(d);
    if (lastFocus && document.contains(lastFocus)) { try { lastFocus.focus(); } catch (e) {} }
    lastFocus = null;
  }
  UI.closeDialog = closeDialog;
  UI.dialog = function (o) {
    var prev = document.getElementById("mbpDialog"); if (prev) prev.parentNode.removeChild(prev);
    else lastFocus = document.activeElement;
    var wrap = document.createElement("div"); wrap.id = "mbpDialog"; wrap.className = "dlgWrap";
    wrap.innerHTML = '<div class="dlg' + (o.wide ? " wide" : "") + '" role="dialog" aria-modal="true" aria-labelledby="dlgTitle" tabindex="-1"><h2 id="dlgTitle">' + esc(o.title) + "</h2>" +
      (o.body ? "<p>" + esc(o.body) + "</p>" : "") + (o.html || "") +
      (o.input != null ? '<input id="dlgIn" aria-label="' + esc(o.placeholder || o.title) + '" value="' + esc(o.input) + '" placeholder="' + esc(o.placeholder || "") + '">' : "") +
      '<div class="dlgBtns">' + (o.onOk ? '<button class="btn" id="dlgNo">' + esc(o.cancelLabel || "Cancel") + "</button>" : "") +
      '<button class="btn ' + (o.danger ? "warn" : "pri") + '" id="dlgYes">' + esc(o.okLabel || "OK") + "</button></div></div>";
    document.body.appendChild(wrap);
    var input = document.getElementById("dlgIn");
    (input || wrap.querySelector("input,select,textarea") || document.getElementById("dlgYes")).focus();
    /* Keep keyboard focus inside the dialog; Escape closes it. */
    wrap.addEventListener("keydown", function (e) {
      if (e.key === "Escape") { e.preventDefault(); closeDialog(); return; }
      if (e.key !== "Tab") return;
      var f = Array.prototype.filter.call(wrap.querySelectorAll('a[href],button:not([disabled]),input:not([disabled]):not([type="hidden"]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])'),
        function (el) { return el.offsetParent !== null; });
      if (!f.length) return;
      var first = f[0], last = f[f.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    });
    var no = document.getElementById("dlgNo"); if (no) no.onclick = closeDialog;
    wrap.onclick = function (e) { if (e.target === wrap) closeDialog(); };
    document.getElementById("dlgYes").onclick = function () {
      var val = input ? input.value : wrap;
      if (o.keepOpen) { if (o.onOk) o.onOk(val, closeDialog); return; }
      closeDialog(); if (o.onOk) o.onOk(val);
    };
    if (o.onOpen) o.onOpen(wrap);
  };
  UI.confirm = function (title, body, onYes, okLabel) { UI.dialog({ title: title, body: body, okLabel: okLabel || "Confirm", danger: true, onOk: onYes }); };
  UI.notify = function (title, body) { UI.dialog({ title: title, body: body, okLabel: "Close" }); };

  /* ---------------- accessible names ----------------
     Screens are built from HTML strings. Any input that ends up without a visible <label>
     gets an accessible name from its placeholder, title or table column header. */
  function nameControls(root) {
    Array.prototype.forEach.call(root.querySelectorAll("input:not([type=hidden]),select,textarea"), function (el) {
      if (el.getAttribute("aria-label") || el.getAttribute("aria-labelledby") || el.closest("label")) return;
      if (el.id && root.ownerDocument.querySelector('label[for="' + el.id + '"]')) return;
      var name = el.getAttribute("placeholder") || el.getAttribute("title");
      var td = el.closest("td");
      if (!name && td) {
        var table = td.closest("table"), th = table && table.querySelectorAll("thead th")[td.cellIndex];
        if (th && th.textContent.trim()) name = th.textContent.trim();
      }
      if (name) el.setAttribute("aria-label", name);
    });
  }
  UI.watchLabels = function (root) {
    if (!root || root._labelled) return; root._labelled = true;
    nameControls(root);
    if (w.MutationObserver) new MutationObserver(function () { nameControls(root); }).observe(root, { childList: true, subtree: true });
  };

  /* ---------------- accessible names ----------------
     Screens are built from HTML strings. Any input that ends up without a visible <label>
     gets an accessible name from its placeholder, title or table column header. */
  function nameControls(root) {
    Array.prototype.forEach.call(root.querySelectorAll("input:not([type=hidden]),select,textarea"), function (el) {
      if (el.getAttribute("aria-label") || el.getAttribute("aria-labelledby") || el.closest("label")) return;
      if (el.id && root.ownerDocument.querySelector('label[for="' + el.id + '"]')) return;
      var name = el.getAttribute("placeholder") || el.getAttribute("title");
      var td = el.closest("td");
      if (!name && td) {
        var table = td.closest("table"), th = table && table.querySelectorAll("thead th")[td.cellIndex];
        if (th && th.textContent.trim()) name = th.textContent.trim();
      }
      if (name) el.setAttribute("aria-label", name);
    });
  }
  UI.watchLabels = function (root) {
    if (!root || root._labelled) return; root._labelled = true;
    nameControls(root);
    if (w.MutationObserver) new MutationObserver(function () { nameControls(root); }).observe(root, { childList: true, subtree: true });
  };

  /* ---------------- accessible names ----------------
     Screens are built from HTML strings. Any input that ends up without a visible <label>
     gets an accessible name from its placeholder, title or table column header. */
  function nameControls(root) {
    Array.prototype.forEach.call(root.querySelectorAll("input:not([type=hidden]),select,textarea"), function (el) {
      if (el.getAttribute("aria-label") || el.getAttribute("aria-labelledby") || el.closest("label")) return;
      if (el.id && root.ownerDocument.querySelector('label[for="' + el.id + '"]')) return;
      var name = el.getAttribute("placeholder") || el.getAttribute("title");
      var td = el.closest("td");
      if (!name && td) {
        var table = td.closest("table"), th = table && table.querySelectorAll("thead th")[td.cellIndex];
        if (th && th.textContent.trim()) name = th.textContent.trim();
      }
      if (name) el.setAttribute("aria-label", name);
    });
  }
  UI.watchLabels = function (root) {
    if (!root || root._labelled) return; root._labelled = true;
    nameControls(root);
    if (w.MutationObserver) new MutationObserver(function () { nameControls(root); }).observe(root, { childList: true, subtree: true });
  };

  /* ---------------- export ---------------- */
  UI.download = function (name, data, mime) {
    var url = URL.createObjectURL(data instanceof Blob ? data : new Blob([data], { type: mime || "text/plain" }));
    var a = document.createElement("a"); a.href = url; a.download = name; document.body.appendChild(a); a.click(); a.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 2000);
  };
  UI.csv = function (rows) {
    /* Text that starts like a spreadsheet formula is prefixed with ' so a customer name such as
       "=HYPERLINK(...)" cannot run as a formula when the CSV is opened. Plain numbers are untouched. */
    function cell(c) {
      var s = String(c == null ? "" : c);
      if (/^[=+\-@\t\r]/.test(s) && !/^[-+]?\d[\d,]*(\.\d+)?$/.test(s)) s = "'" + s;
      return '"' + s.replace(/"/g, '""') + '"';
    }
    return "\ufeff" + rows.map(function (r) { return r.map(cell).join(","); }).join("\r\n");
  };
  UI.xlsx = function (name, rows, sheet) {
    if (!w.XLSX) { UI.download(name.replace(/\.xlsx$/, ".csv"), UI.csv(rows), "text/csv"); return; }
    var wb = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(rows), (sheet || "Report").slice(0, 31));
    XLSX.writeFile(wb, name);
  };

  w.UI = UI;
})(window);
