/* Registers the service worker so the platform installs and runs offline.
   Skipped on file:// where service workers are not permitted. */
if ("serviceWorker" in navigator && location.protocol.indexOf("http") === 0) {
  window.addEventListener("load", function () {
    navigator.serviceWorker.register("sw.js").catch(function () { /* offline support unavailable */ });
  });
}
