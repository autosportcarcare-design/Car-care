const CACHE = "business-platform-v3";
const SHELL = [
  "./index.html",
  "./login.html",
  "./setup.html",
  "./dashboard.html",
  "./new-transaction.html",
  "./day-book.html",
  "./voucher-view.html",
  "./parties.html",
  "./vehicles.html",
  "./stock.html",
  "./job-cards.html",
  "./reports.html",
  "./search.html",
  "./print-preview.html",
  "./document-designer.html",
  "./users.html",
  "./backup.html",
  "./settings.html",
  "./manifest.webmanifest",
  "./assets/platform.css",
  "./assets/ui.js",
  "./assets/cloud.js",
  "./assets/doc-render.js",
  "./assets/pwa.js",
  "./assets/app-icon.svg",
  "./assets/vendor/supabase.js",
  "./assets/vendor/xlsx.mini.min.js",
  "./assets/pages/editor.js",
  "./assets/pages/voucher.js",
  "./assets/pages/daybook.js",
  "./assets/pages/dashboard.js",
  "./assets/pages/search.js",
  "./assets/pages/stock.js",
  "./assets/pages/jobs.js",
  "./assets/pages/reports.js",
  "./assets/pages/settings.js",
  "./assets/pages/designer.js",
  "./assets/pages/backup.js",
  "./assets/pages/print.js"
];

self.addEventListener("install", function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) { return c.addAll(SHELL); }).then(function () { return self.skipWaiting(); }));
});
self.addEventListener("activate", function (e) {
  e.waitUntil(caches.keys().then(function (keys) {
    return Promise.all(keys.filter(function (k) { return k !== CACHE; }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});
/* Network first so a redeploy is picked up, cache as the offline fallback. */
self.addEventListener("fetch", function (e) {
  if (e.request.method !== "GET" || new URL(e.request.url).origin !== location.origin) return;
  e.respondWith(fetch(e.request).then(function (res) {
    var copy = res.clone();
    caches.open(CACHE).then(function (c) { c.put(e.request, copy); });
    return res;
  }).catch(function () { return caches.match(e.request); }));
});
