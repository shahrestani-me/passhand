// Passhand — Chrome side.
// Keeps a connection to the local helper (which owns the Keychain) and does two things on its behalf:
//   inspect: find the tab the agent is on, report its real origin and the visible input fields (no values)
//   fill:    write the values the helper sends into those fields, after re-checking the origin
// It never decides which password to use and never sends a password anywhere but the page.
// It also forwards requests from its own settings page (options.html) to the helper, which owns the
// Keychain and asks for Touch ID before any change. Saved passwords never come back this way.

const HOST = "me.shahrestani.passhand";
let port = null;

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    console.warn("[passhand] could not start helper:", e);
    port = null;
    return;
  }
  port.onMessage.addListener((msg) => {
    if (msg.req) return settingsReply(msg);
    handle(msg).then(
      (result) => send({ id: msg.id, ok: true, ...result }),
      (err) => send({ id: msg.id, ok: false, error: String((err && err.message) || err) })
    );
  });
  port.onDisconnect.addListener(() => {
    console.warn("[passhand] helper disconnected:", chrome.runtime.lastError?.message);
    port = null;
    for (const req of [...settingsWaiting.keys()]) {
      settingsReply({ req, ok: false, error: "Passhand's helper stopped. Reload this page and try again." });
    }
  });
}

function send(message) {
  try {
    if (port) port.postMessage(message);
  } catch (e) {
    console.warn("[passhand] send failed:", e);
  }
}

// Reconnect on browser start, on install, and once a minute if the helper went away.
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.alarms.create("passhand-reconnect", { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(connect);
connect();

// ---------- Settings page ----------

const SETTINGS_PAGE = chrome.runtime.getURL("options.html");
// Which fields each request may carry to the helper; anything else the page sends is dropped.
const SETTINGS_FIELDS = {
  "logins.list": [],
  "logins.save": ["site", "username", "password", "auto"],
  "logins.remove": ["origin", "username"],
  "logins.auto": ["origin", "username", "auto"],
};
const SETTINGS_TIMEOUT_MS = 120 * 1000; // longer than the helper's 90 s Touch ID timeout
const settingsWaiting = new Map();

chrome.action.onClicked.addListener(() => chrome.runtime.openOptionsPage());

// Only Passhand's own settings page may manage logins. Web pages can't reach this listener (there is no
// externally_connectable), and the code injected into pages never sends messages.
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!isSettingsPage(sender)) {
    sendResponse({ ok: false, error: "Only Passhand's settings page can manage logins." });
    return false;
  }
  const fields = msg && Object.hasOwn(SETTINGS_FIELDS, msg.cmd) ? SETTINGS_FIELDS[msg.cmd] : null;
  if (!fields) {
    sendResponse({ ok: false, error: "Unknown settings request." });
    return false;
  }
  const request = { cmd: msg.cmd };
  for (const f of fields) if (f in msg) request[f] = msg[f];
  askHelper(request).then(sendResponse);
  return true; // answer asynchronously
});

function isSettingsPage(sender) {
  return sender.id === chrome.runtime.id && typeof sender.url === "string" &&
    sender.url.split(/[?#]/)[0] === SETTINGS_PAGE;
}

function askHelper(request) {
  connect();
  if (!port) {
    return Promise.resolve({ ok: false, error: "Passhand's helper isn't installed or couldn't start. Run ./install.sh, then reload the extension." });
  }
  const req = crypto.randomUUID();
  return new Promise((resolve) => {
    const timer = setTimeout(
      () => settingsReply({ req, ok: false, error: "The helper didn't answer in time. Was the Touch ID prompt left open?" }),
      SETTINGS_TIMEOUT_MS);
    settingsWaiting.set(req, { resolve, timer });
    send({ ...request, req });
  });
}

function settingsReply(msg) {
  const waiting = settingsWaiting.get(msg.req);
  if (!waiting) return;
  settingsWaiting.delete(msg.req);
  clearTimeout(waiting.timer);
  const { req, id, ...reply } = msg;
  waiting.resolve(reply);
}

async function handle(msg) {
  switch (msg.cmd) {
    case "ping":
      return { pong: true };
    case "locate":
      return locate(msg.page_url, msg.tab_id);
    case "inspect":
      return inspect(msg.page_url, msg.tab_id);
    case "fill":
      return fill(msg);
    default:
      throw new Error("Unknown command: " + msg.cmd);
  }
}

// When several browsers run Passhand, the MCP side asks each one this before filling, and fills only if
// exactly one browser has a match of any kind. Reads nothing from the page.
async function locate(pageUrl, tabId) {
  const { by, tabs } = await matchTabs(pageUrl, tabId);
  return { by, count: tabs.length };
}

async function findTab(pageUrl, tabId) {
  const { tabs } = await matchTabs(pageUrl, tabId);
  if (!tabs.length) throw new Error("No open tab matches " + pageUrl + ". Pass the URL of the login tab exactly as it is open now.");
  if (tabs.length > 1) {
    throw new Error(tabs.length + " tabs are open on " + pageUrl + ", so nothing was filled (it could be the wrong tab). " +
      "Pass tab_id, make this tab's URL unique (for example add ?login=1), or close the other tabs.");
  }
  return tabs[0];
}

async function matchTabs(pageUrl, tabId) {
  let wanted;
  try {
    wanted = new URL(pageUrl);
  } catch {
    throw new Error("page_url is not a valid URL");
  }
  const parse = (u) => {
    try { return new URL(u); } catch { return null; }
  };
  const withoutHash = (u) => { const x = parse(u); if (!x) return null; x.hash = ""; return x.href; };
  const originAndPath = (u) => { const x = parse(u); return x ? x.origin + x.pathname : null; };

  // A tab id from the caller wins, as long as that tab really is on this page.
  if (Number.isInteger(tabId)) {
    try {
      const t = await chrome.tabs.get(tabId);
      if (t.url && originAndPath(t.url) === originAndPath(wanted.href)) return { by: "tab_id", tabs: [t] };
    } catch { /* not a Chrome tab id; fall back to URL matching */ }
  }

  const tabs = (await chrome.tabs.query({})).filter((t) => t.url);
  const exact = tabs.filter((t) => withoutHash(t.url) === withoutHash(wanted.href));
  if (exact.length) return { by: "url", tabs: exact };
  const samePath = tabs.filter((t) => originAndPath(t.url) === originAndPath(wanted.href));
  return { by: samePath.length ? "path" : null, tabs: samePath };
}

async function inspect(pageUrl, tabId) {
  const tab = await findTab(pageUrl, tabId);
  const origin = new URL(tab.url).origin;
  const [res] = await chrome.scripting.executeScript({
    target: { tabId: tab.id, frameIds: [0] },
    func: snapshotPage,
  });
  const snap = res && res.result;
  if (!snap) throw new Error("Couldn't read the page (it may still be loading, or it's a browser page).");
  if (snap.origin !== origin) throw new Error("The page changed while it was being read; try again.");
  return { tab_id: tab.id, origin, fields: snap.fields, guess: snap.guess };
}

async function fill({ tab_id, expected_origin, items, submit }) {
  const tab = await chrome.tabs.get(tab_id);
  if (!tab.url || new URL(tab.url).origin !== expected_origin) {
    throw new Error("The tab moved to a different site, so nothing was filled.");
  }
  const [res] = await chrome.scripting.executeScript({
    target: { tabId: tab_id, frameIds: [0] },
    func: fillPage,
    args: [expected_origin, items, !!submit],
  });
  const r = res && res.result;
  if (!r || !r.ok) throw new Error((r && r.error) || "Filling the page failed.");
  return { filled: r.filled, submitted: r.submitted, submit_note: r.submit_note || undefined };
}

// ---------- Runs inside the page (isolated world). Must be self-contained. ----------

function snapshotPage() {
  const TEXTISH = ["text", "email", "tel"];
  const ac = (el) => (el.getAttribute("autocomplete") || "").toLowerCase();
  const labelOf = (el) => {
    const lab = el.labels && el.labels[0];
    const t = (lab && (lab.innerText || lab.textContent)) || el.getAttribute("aria-label") || el.placeholder || "";
    return t.replace(/\s+/g, " ").trim().slice(0, 80);
  };
  const isVisible = (el) => {
    if (el.disabled || el.readOnly) return false;
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    const s = getComputedStyle(el);
    if (s.visibility === "hidden" || s.display === "none" || (s.opacity !== "" && Number(s.opacity) === 0)) return false;
    if (el.closest("[aria-hidden='true'], [hidden], [inert]")) return false;
    return true;
  };

  document.querySelectorAll("[data-cv-ref]").forEach((e) => e.removeAttribute("data-cv-ref"));
  const inputs = [...document.querySelectorAll("input")].filter(
    (el) => (el.type === "password" || TEXTISH.includes(el.type)) && isVisible(el)
  );
  const fields = inputs.map((el, i) => {
    const ref = "f" + (i + 1);
    el.setAttribute("data-cv-ref", ref);
    return { ref, type: el.type, name: el.name || "", id: el.id || "", autocomplete: ac(el), label: labelOf(el) };
  });

  // Password: the one marked current-password, or the only one that isn't a "new password" field.
  const pw = inputs.filter((el) => el.type === "password");
  const current = pw.filter((el) => ac(el).includes("current-password"));
  const notNew = pw.filter((el) => !ac(el).includes("new-password"));
  const pass = current[0] || (notNew.length === 1 ? notNew[0] : null);

  // Username: explicit autocomplete hint, else the last text field before the password in the same form,
  // else something that clearly looks like a login identifier.
  const text = inputs.filter((el) => el.type !== "password");
  const looksLikeLogin = (el) =>
    el.type === "email" ||
    /user|email|e-mail|login|account|identifier|benutzer|anmelde/i.test([el.name, el.id, labelOf(el)].join(" "));
  let user = text.find((el) => /\b(username|email)\b/.test(ac(el))) || null;
  if (!user && pass) {
    const scope = pass.form ? text.filter((el) => el.form === pass.form) : text;
    const before = scope.filter((el) => el.compareDocumentPosition(pass) & Node.DOCUMENT_POSITION_FOLLOWING);
    user = before[before.length - 1] || null;
  }
  if (!user) user = text.find(looksLikeLogin) || null;

  return {
    origin: location.origin,
    fields,
    guess: {
      username_ref: user ? user.getAttribute("data-cv-ref") : null,
      password_ref: pass ? pass.getAttribute("data-cv-ref") : null,
    },
  };
}

function fillPage(expectedOrigin, items, submit) {
  if (location.origin !== expectedOrigin) {
    return { ok: false, error: "This page's origin doesn't match the saved login, so nothing was filled." };
  }

  // Validate everything before touching anything, so a failure never leaves a half-filled form.
  const targets = [];
  for (const it of items) {
    const el = document.querySelector(`input[data-cv-ref="${CSS.escape(it.ref)}"]`);
    if (!el || !el.isConnected) return { ok: false, error: "The form changed; call fill_login again." };
    if (it.kind === "password" && el.type !== "password") {
      return { ok: false, error: "Refusing to put a password into a non-password field." };
    }
    if (it.kind === "username" && !["text", "email", "tel"].includes(el.type)) {
      return { ok: false, error: "The username field has an unexpected type." };
    }
    targets.push([el, it]);
  }

  // Native value setter + input/change events, so React/Vue/Angular forms register the change.
  const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
  const filled = [];
  let lastEl = null;
  for (const [el, it] of targets) {
    el.focus();
    setValue.call(el, it.value);
    el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertReplacementText" }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    el.blur();
    filled.push(it.kind);
    lastEl = el;
  }

  let submitted = false;
  let submit_note = null;
  if (submit && lastEl) {
    const form = lastEl.form;
    if (form && typeof form.requestSubmit === "function") {
      try {
        form.requestSubmit();
        submitted = true;
      } catch (e) {
        submit_note = "The form couldn't be submitted automatically; click the sign-in button.";
      }
    } else {
      submit_note = "There's no form to submit automatically; click the sign-in button.";
    }
  }

  document.querySelectorAll("[data-cv-ref]").forEach((e) => e.removeAttribute("data-cv-ref"));
  return { ok: true, filled, submitted, submit_note };
}
