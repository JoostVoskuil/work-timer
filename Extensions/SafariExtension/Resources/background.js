// Reports only { hostname } of the active tab. Never sends path, query, title or page content.
const session = crypto.randomUUID();
let seq = 0;

function hostState(tab) {
  if (!tab) return { state: "unavailable" };
  if (tab.incognito) return { state: "private" };
  try {
    const u = new URL(tab.url);
    if (u.protocol !== "http:" && u.protocol !== "https:") return { state: "unsupported" };
    return { state: "domain", host: u.hostname };
  } catch (_) {
    return { state: "unsupported" };
  }
}

async function report() {
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  const msg = { id: crypto.randomUUID(), session, seq: ++seq, observedAt: Date.now(), ...hostState(tab) };
  try { await browser.runtime.sendNativeMessage("application.id", msg); } catch (_) { /* app unavailable; next heartbeat retries */ }
}

browser.tabs.onActivated.addListener(report);
browser.tabs.onUpdated.addListener((_id, change) => { if (change.url || change.status === "complete") report(); });
browser.windows.onFocusChanged.addListener(report);
browser.alarms.create("heartbeat", { periodInMinutes: 0.1 });
browser.alarms.onAlarm.addListener(report);
report();
