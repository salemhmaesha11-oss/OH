(() => {
  const DB_NAME = "oh-pwa";
  const DB_VERSION = 1;
  const STORE_NAME = "requests";
  const SYNC_TAG = "oh-offline-orders";
  let databasePromise;
  let configuration;

  function openDatabase() {
    if (!databasePromise) {
      databasePromise = new Promise((resolve, reject) => {
        const request = indexedDB.open(DB_NAME, DB_VERSION);
        request.onupgradeneeded = () => {
          const database = request.result;
          if (!database.objectStoreNames.contains(STORE_NAME)) {
            database.createObjectStore(STORE_NAME, { keyPath: "id" });
          }
        };
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      });
    }
    return databasePromise;
  }

  async function withStore(mode, action) {
    const database = await openDatabase();
    return new Promise((resolve, reject) => {
      const transaction = database.transaction(STORE_NAME, mode);
      const request = action(transaction.objectStore(STORE_NAME));
      transaction.oncomplete = () => resolve(request?.result);
      transaction.onerror = () => reject(transaction.error);
      transaction.onabort = () => reject(transaction.error || new Error("تعذّر الوصول إلى الطلبات المحفوظة."));
    });
  }

  async function requestSync() {
    if (!("serviceWorker" in navigator) || !navigator.onLine) return;
    if ((await counts()).pending === 0) return;
    const registration = await navigator.serviceWorker.ready;
    if (registration.sync) {
      try {
        await registration.sync.register(SYNC_TAG);
        return;
      } catch (error) {
        console.warn("Background Sync unavailable; using connectivity retries instead.", error);
      }
    }
    (registration.active || navigator.serviceWorker.controller)?.postMessage({ type: "SYNC_QUEUE" });
  }

  async function enqueue({ id, body }) {
    if (!configuration) throw new Error("لم تكتمل تهيئة حفظ الطلبات دون اتصال.");
    await withStore("readwrite", store => store.put({
      id,
      body,
      url: `${configuration.supabaseUrl}/rest/v1/rpc/place_guest_order`,
      apiKey: configuration.publishableKey,
      status: "pending",
      queuedAt: new Date().toISOString()
    }));
    await requestSync();
  }

  async function counts() {
    const records = await withStore("readonly", store => store.getAll());
    return records.reduce((result, record) => {
      if (record.status === "failed") result.failed += 1;
      else result.pending += 1;
      return result;
    }, { pending: 0, failed: 0 });
  }

  window.ohPwaQueue = {
    configure(value) {
      configuration = value;
    },
    enqueue,
    counts
  };

  function notifyQueueChange(detail) {
    window.dispatchEvent(new CustomEvent("oh-pwa-queue-change", { detail }));
  }

  if ("serviceWorker" in navigator && window.isSecureContext) {
    navigator.serviceWorker.register("/sw.js")
      .then(requestSync)
      .catch(error => console.error("تعذّر تسجيل Service Worker:", error));
    navigator.serviceWorker.addEventListener("message", event => {
      if (event.data?.type === "QUEUE_SYNCED" || event.data?.type === "QUEUE_FAILED") {
        notifyQueueChange(event.data);
      }
    });

    const retryQueuedOrders = () => requestSync()
      .catch(error => console.error("تعذّرت إعادة محاولة إرسال الطلبات المحفوظة:", error));
    window.addEventListener("online", retryQueuedOrders);
    window.setInterval(retryQueuedOrders, 30000);
  }
})();
