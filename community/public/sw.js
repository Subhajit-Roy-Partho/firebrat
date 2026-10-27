/* Firebrat Community service worker.
   - Cache-first for the app shell (same-origin GET), runtime-filled.
   - Network-only for archive.org audio/metadata and Firebase backends.
   - Offline navigations fall back to the cached app shell. */

const CACHE = "firebrat-community-v1";
const SHELL = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./icon.svg",
  "./icon-192.png",
  "./icon-512.png",
];

const NETWORK_ONLY = [
  /(^|\.)archive\.org$/,
  /firestore\.googleapis\.com$/,
  /identitytoolkit\.googleapis\.com$/,
  /securetoken\.googleapis\.com$/,
  /firebaseinstallations\.googleapis\.com$/,
];

function networkOnlyHost(hostname) {
  return NETWORK_ONLY.some((re) => re.test(hostname));
}

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()).catch(() => {}),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET") return;
  const url = new URL(request.url);

  // Audio, metadata and auth traffic must always hit the network.
  if (networkOnlyHost(url.hostname)) return;

  // Navigations: network first, fall back to cached shell offline.
  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put("./index.html", copy)).catch(() => {});
          return res;
        })
        .catch(() => caches.match("./index.html").then((r) => r || caches.match("./"))),
    );
    return;
  }

  // Same-origin static assets (and hashed Vite bundles): cache-first, fill at runtime.
  if (url.origin === self.location.origin) {
    event.respondWith(
      caches.match(request).then((hit) => {
        if (hit) return hit;
        return fetch(request).then((res) => {
          if (res && (res.ok || res.type === "opaque")) {
            const copy = res.clone();
            caches.open(CACHE).then((c) => c.put(request, copy)).catch(() => {});
          }
          return res;
        });
      }),
    );
  }
});
