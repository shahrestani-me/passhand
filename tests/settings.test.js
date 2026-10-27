// Tests for the settings page (options.html / options.js) and how the background worker forwards its
// requests to the helper. chrome.* is faked; the helper is the fake native port.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const read = (name) => readFileSync(new URL(`../extension/${name}`, import.meta.url), "utf8");
const EXT_ID = "alpckagkehodlliniailejachglpeinb";
const SETTINGS_URL = `chrome-extension://${EXT_ID}/options.html`;

// ---------- background.js ----------

function loadBackground() {
  const listeners = {};
  const on = (name) => ({ addListener: (fn) => { listeners[name] = fn; } });
  const posted = [];
  const port = {
    postMessage: (m) => posted.push(structuredClone(m)),
    onMessage: on("port.message"),
    onDisconnect: on("port.disconnect"),
  };
  const chrome = {
    runtime: {
      id: EXT_ID,
      getURL: (p) => `chrome-extension://${EXT_ID}/${p}`,
      connectNative: () => port,
      openOptionsPage: () => {},
      onStartup: on("startup"),
      onInstalled: on("installed"),
      onMessage: on("message"),
    },
    alarms: { create: () => {}, onAlarm: on("alarm") },
    action: { onClicked: on("action") },
  };
  const context = { chrome, console, crypto, setTimeout, clearTimeout, URL, structuredClone };
  vm.runInNewContext(read("background.js"), context);

  // Sends a message as `sender` and resolves with what the worker answers.
  const message = (msg, sender) => new Promise((resolve) => listeners.message(msg, sender, resolve));
  const helperReplies = (reply) => listeners["port.message"]({ ...reply, req: posted.at(-1).req });
  return { message, posted, helperReplies, disconnect: () => listeners["port.disconnect"]() };
}

const fromSettings = { id: EXT_ID, url: SETTINGS_URL, tab: { id: 7 } };

test("a web page can't manage logins", async () => {
  const bg = loadBackground();
  const reply = await bg.message({ cmd: "logins.list" }, { id: EXT_ID, url: "https://evil.example/", tab: { id: 3 } });
  assert.equal(reply.ok, false);
  assert.equal(bg.posted.length, 0, "nothing reaches the helper");
});

test("another extension can't manage logins", async () => {
  const bg = loadBackground();
  const reply = await bg.message({ cmd: "logins.list" }, { id: "someoneelse", url: `chrome-extension://someoneelse/options.html` });
  assert.equal(reply.ok, false);
  assert.equal(bg.posted.length, 0);
});

test("a look-alike path inside the extension is refused", async () => {
  const bg = loadBackground();
  const reply = await bg.message({ cmd: "logins.list" }, { id: EXT_ID, url: `chrome-extension://${EXT_ID}/options.html.evil` });
  assert.equal(reply.ok, false);
  assert.equal(bg.posted.length, 0);
});

test("unknown commands are refused, including the helper's own fill command", async () => {
  const bg = loadBackground();
  for (const cmd of ["fill", "inspect", "logins.password", undefined]) {
    const reply = await bg.message({ cmd }, fromSettings);
    assert.equal(reply.ok, false, String(cmd));
  }
  assert.equal(bg.posted.length, 0);
});

test("the settings page's save reaches the helper with only the expected fields", async () => {
  const bg = loadBackground();
  const pending = bg.message(
    { cmd: "logins.save", site: "example.com", username: "qa", password: "not-a-real-password", auto: false,
      tab_id: 1, expected_origin: "https://evil.example" },
    { ...fromSettings, url: SETTINGS_URL + "#add" });
  const sent = bg.posted.at(-1);
  assert.deepEqual(Object.keys(sent).sort(), ["auto", "cmd", "password", "req", "site", "username"]);
  bg.helperReplies({ ok: true, origin: "https://example.com", username: "qa", replaced: false });
  const reply = await pending;
  assert.equal(reply.ok, true);
  assert.equal(reply.origin, "https://example.com");
  assert.equal("req" in reply, false, "internal ids stay internal");
});

test("a list reply is passed through to the page", async () => {
  const bg = loadBackground();
  const pending = bg.message({ cmd: "logins.list" }, fromSettings);
  bg.helperReplies({ ok: true, logins: [{ origin: "https://example.com", username: "a", auto: false }] });
  assert.deepEqual((await pending).logins, [{ origin: "https://example.com", username: "a", auto: false }]);
});

test("a helper that goes away fails the waiting request instead of hanging", async () => {
  const bg = loadBackground();
  const pending = bg.message({ cmd: "logins.list" }, fromSettings);
  bg.disconnect();
  const reply = await pending;
  assert.equal(reply.ok, false);
});

// ---------- options.html / options.js ----------

async function loadPage(handler) {
  const dom = new JSDOM(read("options.html").replace(/<script[^>]*><\/script>/, ""), {
    url: SETTINGS_URL, runScripts: "outside-only",
  });
  const w = dom.window;
  const sent = [];
  w.chrome = {
    runtime: {
      sendMessage: async (m) => {
        sent.push(JSON.parse(JSON.stringify(m)));
        return handler(m);
      },
    },
  };
  w.eval(read("options.js"));
  await settle();
  return { w, doc: w.document, sent };
}

const settle = () => new Promise((r) => setTimeout(r, 0));

const twoAccounts = [
  { origin: "https://app.example.com", username: "admin@example.com", auto: false },
  { origin: "https://app.example.com", username: "qa@example.com", auto: true },
  { origin: "https://other.example", username: "me", auto: false },
];

test("saved logins are grouped by site, with several accounts per site", async () => {
  const { doc } = await loadPage(() => ({ ok: true, logins: twoAccounts }));
  const sites = [...doc.querySelectorAll(".site")];
  assert.equal(sites.length, 2);
  assert.equal(sites[0].querySelector(".origin").textContent, "https://app.example.com");
  assert.deepEqual([...sites[0].querySelectorAll(".user")].map((e) => e.textContent), ["admin@example.com", "qa@example.com"]);
  assert.deepEqual([...sites[0].querySelectorAll("input[type=checkbox]")].map((e) => e.checked), [false, true]);
});

test("usernames are shown as text, never as markup", async () => {
  const { doc } = await loadPage(() => ({
    ok: true, logins: [{ origin: "https://example.com", username: "<img src=x onerror=alert(1)>", auto: false }],
  }));
  assert.equal(doc.querySelector(".account img"), null);
  assert.equal(doc.querySelector(".user").textContent, "<img src=x onerror=alert(1)>");
});

test("saving sends the form, then clears the password and keeps the site", async () => {
  const { doc, sent } = await loadPage((m) => m.cmd === "logins.save"
    ? { ok: true, origin: "https://example.com", username: "qa", auto: false, replaced: false }
    : { ok: true, logins: [] });
  const f = doc.getElementById("add").elements;
  f.site.value = " example.com ";
  f.username.value = "qa";
  f.password.value = "not-a-real-password";
  doc.getElementById("add").dispatchEvent(new doc.defaultView.Event("submit", { cancelable: true }));
  await settle(); await settle();
  assert.deepEqual(sent.find((m) => m.cmd === "logins.save"),
    { cmd: "logins.save", site: "example.com", username: "qa", password: "not-a-real-password", auto: false });
  assert.equal(f.password.value, "");
  assert.equal(f.site.value, " example.com ");
  assert.match(doc.getElementById("status").textContent, /Saved qa on https:\/\/example.com/);
});

test("a refused save shows the reason and keeps what was typed", async () => {
  const { doc } = await loadPage((m) => m.cmd === "logins.save"
    ? { ok: false, error: "Touch ID was not confirmed, so nothing was changed." }
    : { ok: true, logins: [] });
  const f = doc.getElementById("add").elements;
  f.site.value = "example.com";
  f.username.value = "qa";
  f.password.value = "typed";
  doc.getElementById("add").dispatchEvent(new doc.defaultView.Event("submit", { cancelable: true }));
  await settle(); await settle();
  assert.equal(doc.getElementById("status").className, "error");
  assert.match(doc.getElementById("status").textContent, /Touch ID was not confirmed/);
  assert.equal(f.password.value, "typed");
});

test("the page never receives or shows a password from the list", async () => {
  const { doc } = await loadPage(() => ({ ok: true, logins: twoAccounts }));
  assert.equal(doc.querySelectorAll("#logins input[type=password], #logins input[type=text]").length, 0);
});

test("removing an account asks the helper for exactly that login", async () => {
  const { doc, sent } = await loadPage((m) => m.cmd === "logins.list" ? { ok: true, logins: twoAccounts } : { ok: true });
  doc.querySelectorAll(".site")[0].querySelectorAll("button.danger")[1].click();
  await settle(); await settle();
  assert.deepEqual(sent.find((m) => m.cmd === "logins.remove"),
    { cmd: "logins.remove", origin: "https://app.example.com", username: "qa@example.com" });
});

test("the auto switch only changes after the helper confirms", async () => {
  const { doc, sent } = await loadPage((m) => m.cmd === "logins.list"
    ? { ok: true, logins: twoAccounts }
    : { ok: false, error: "Touch ID was not confirmed, so nothing was changed." });
  const box = doc.querySelector(".site input[type=checkbox]");
  box.click();
  await settle(); await settle();
  assert.deepEqual(sent.find((m) => m.cmd === "logins.auto"),
    { cmd: "logins.auto", origin: "https://app.example.com", username: "admin@example.com", auto: true });
  assert.equal(box.checked, false, "still off after a refused Touch ID");
});

test("only real site addresses are accepted, and the preview shows the exact origin", async () => {
  const { w } = await loadPage(() => ({ ok: true, logins: [] }));
  const cases = {
    "staging.example.com": "https://staging.example.com",
    " https://Example.COM:443/login?x=1 ": "https://example.com",
    "https://example.com:8443": "https://example.com:8443",
    "http://localhost:3000": "http://localhost:3000",
    "http://app.test": "http://app.test",
    "alice": null,
    "Pa55word@123": null,
    "alice@example.com": null,
    "https://alice:secret@example.com": null,
    "http://example.com": null,
    "alice.": null,
    ".com": null,
    "": null,
  };
  for (const [input, expected] of Object.entries(cases)) {
    assert.equal(w.siteOrigin(input), expected, JSON.stringify(input));
  }
});

test("typing a site shows where it will be saved, or why it can't be", async () => {
  const { doc } = await loadPage(() => ({ ok: true, logins: [] }));
  const site = doc.getElementById("add").elements.site;
  const preview = doc.getElementById("site-preview");
  site.value = "staging.example.com";
  site.dispatchEvent(new doc.defaultView.Event("input"));
  assert.equal(preview.textContent, "Will be saved for https://staging.example.com");
  site.value = "alice";
  site.dispatchEvent(new doc.defaultView.Event("input"));
  assert.equal(preview.className, "hint invalid");
});

test("an invalid site is never sent to the helper", async () => {
  const { doc, sent } = await loadPage(() => ({ ok: true, logins: [] }));
  const f = doc.getElementById("add").elements;
  f.site.value = "alice";
  f.username.value = "Pa55word@123";
  f.password.value = "not-a-real-password";
  doc.getElementById("add").dispatchEvent(new doc.defaultView.Event("submit", { cancelable: true }));
  await settle(); await settle();
  assert.equal(sent.some((m) => m.cmd === "logins.save"), false);
  assert.equal(doc.getElementById("status").className, "error");
});

test("'Add another account' fills the site and its preview", async () => {
  const { doc } = await loadPage(() => ({ ok: true, logins: twoAccounts }));
  doc.querySelector(".site button").click();
  assert.equal(doc.getElementById("add").elements.site.value, "https://app.example.com");
  assert.equal(doc.getElementById("site-preview").textContent, "Will be saved for https://app.example.com");
});
