const CACHE_NAME = "oh-pwa-v4";
const SHELL_FILES = [
  "/",
  "/index.html",
  "/manifest.json",
  "/pwa.js",
  "/oh-logo.svg",
  "/oh-header-banner.jpg",
  "/oh-social-card.png",
  "/pwa-icon-180.png",
  "/pwa-icon-192.png",
  "/pwa-icon-512.png"
];
const DB_NAME = "oh-pwa";
const STORE_NAME = "requests";
const SUPABASE_ORIGIN = "https://ukxtuomyjmpdvkiyarjx.supabase.co";
const SYNC_TAG = "oh-offline-orders";

self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(SHELL_FILES)));
  self.skipWaiting();
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(key => key.startsWith("oh-pwa-") && key !== CACHE_NAME).map(key => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", event => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);

  if (request.mode === "navigate") {
    event.respondWith(fetch(request)
      .then(response => {
        if (response.ok) caches.open(CACHE_NAME).then(cache => cache.put("/index.html", response.clone()));
        return response;
      })
      .catch(async () => (await caches.match("/index.html")) || Response.error()));
    return;
  }

  if (url.origin === self.location.origin && SHELL_FILES.includes(url.pathname)) {
    event.respondWith(caches.match(url.pathname).then(cached => cached || fetch(request)));
    return;
  }

  if (["image", "font", "script", "style"].includes(request.destination)) {
    event.respondWith((async () => {
      const cached = await caches.match(request);
      if (cached) {
        event.waitUntil(fetch(request).then(async response => {
          if (response.ok || response.type === "opaque") {
            const cache = await caches.open(CACHE_NAME);
            await cache.put(request, response.clone());
          }
        }).catch(error => console.warn("تعذّر تحديث مورد مخزّن مؤقتاً:", error)));
        return cached;
      }

      try {
        const response = await fetch(request);
        if (response.ok || response.type === "opaque") {
          const cache = await caches.open(CACHE_NAME);
          await cache.put(request, response.clone());
        }
        return response;
      } catch {
        return Response.error();
      }
    })());
  }
});

function openQueueDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(STORE_NAME)) {
        request.result.createObjectStore(STORE_NAME, { keyPath: "id" });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function queueRecords() {
  const database = await openQueueDatabase();
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(STORE_NAME, "readonly");
    const request = transaction.objectStore(STORE_NAME).getAll();
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function updateQueueRecord(record, remove = false) {
  const database = await openQueueDatabase();
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(STORE_NAME, "readwrite");
    const store = transaction.objectStore(STORE_NAME);
    if (remove) store.delete(record.id);
    else store.put(record);
    transaction.oncomplete = resolve;
    transaction.onerror = () => reject(transaction.error);
  });
}

async function notifyClients(message) {
  const clients = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
  clients.forEach(client => client.postMessage(message));
}

async function flushQueue() {
  const records = await queueRecords();
  for (const record of records) {
    if (record.status !== "pending") continue;
    const endpoint = new URL(record.url);
    if (endpoint.origin !== SUPABASE_ORIGIN || endpoint.pathname !== "/rest/v1/rpc/place_guest_order") {
      record.status = "failed";
      record.error = "عنوان خدمة غير صالح";
      await updateQueueRecord(record);
      await notifyClients({ type: "QUEUE_FAILED", id: record.id });
      continue;
    }

    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        apikey: record.apiKey,
        Authorization: `Bearer ${record.apiKey}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify(record.body)
    });

    if (response.ok) {
      await updateQueueRecord(record, true);
      await notifyClients({ type: "QUEUE_SYNCED", id: record.id });
    } else if (response.status >= 400 && response.status < 500) {
      record.status = "failed";
      record.error = `HTTP ${response.status}`;
      await updateQueueRecord(record);
      await notifyClients({ type: "QUEUE_FAILED", id: record.id });
    } else {
      throw new Error(`تعذّر إرسال الطلب المحفوظ (HTTP ${response.status}).`);
    }
  }
}

self.addEventListener("sync", event => {
  if (event.tag === SYNC_TAG) event.waitUntil(flushQueue());
});

self.addEventListener("message", event => {
  if (event.data?.type === "SYNC_QUEUE") {
    event.waitUntil(flushQueue().catch(error => console.error("تعذّرت مزامنة الطلبات المحفوظة:", error)));
  }
});
