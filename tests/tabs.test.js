// Tests for how the background worker finds the tab the agent means (locate / inspect).
// chrome.* is faked; the helper is the fake native port.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const source = readFileSync(new URL("../extension/background.js", import.meta.url), "utf8");

function loadBackground(tabs) {
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
      id: "test",
      getURL: (p) => `chrome-extension://test/${p}`,
      connectNative: () => port,
      onStartup: on("startup"),
      onInstalled: on("installed"),
      onMessage: on("message"),
    },
    alarms: { create: () => {}, onAlarm: on("alarm") },
    action: { onClicked: on("action") },
    tabs: {
      query: async () => tabs,
      get: async (id) => {
        const tab = tabs.find((t) => t.id === id);
        if (!tab) throw new Error("No tab with id: " + id);
        return tab;
      },
    },
  };
  vm.runInNewContext(source, { chrome, console, crypto, setTimeout, clearTimeout, URL, structuredClone });

  // Sends a request as the helper and resolves with the worker's answer.
  let next = 0;
  return (msg) => new Promise((resolve) => {
    const id = String(++next);
    listeners["port.message"]({ ...msg, id });
    const poll = () => {
      const reply = posted.find((m) => m.id === id);
      reply ? resolve(reply) : setTimeout(poll, 1);
    };
    poll();
  });
}

const tabs = [
  { id: 1, url: "https://a.example/login" },
  { id: 2, url: "https://b.example/login?next=/home" },
  { id: 3, url: "https://b.example/login?next=/settings" },
];

test("locate reports an exact URL match", async () => {
  const ask = loadBackground(tabs);
  const r = await ask({ cmd: "locate", page_url: "https://a.example/login" });
  assert.equal(r.ok, true);
  assert.equal(r.by, "url");
  assert.equal(r.count, 1);
});

test("locate falls back to origin and path, and counts every such tab", async () => {
  const ask = loadBackground(tabs);
  const r = await ask({ cmd: "locate", page_url: "https://b.example/login" });
  assert.equal(r.by, "path");
  assert.equal(r.count, 2);
});

test("locate prefers a tab_id that is on the page", async () => {
  const ask = loadBackground(tabs);
  const r = await ask({ cmd: "locate", page_url: "https://b.example/login", tab_id: 3 });
  assert.equal(r.by, "tab_id");
  assert.equal(r.count, 1);
});

test("a tab_id on another page, or one this browser doesn't have, is ignored", async () => {
  const ask = loadBackground(tabs);
  assert.equal((await ask({ cmd: "locate", page_url: "https://a.example/login", tab_id: 2 })).by, "url");
  assert.equal((await ask({ cmd: "locate", page_url: "https://a.example/login", tab_id: 99 })).by, "url");
});

test("locate with no matching tab is an answer, not an error", async () => {
  const ask = loadBackground(tabs);
  const r = await ask({ cmd: "locate", page_url: "https://c.example/login" });
  assert.equal(r.ok, true);
  assert.equal(r.by, null);
  assert.equal(r.count, 0);
});

test("an invalid page_url is an error", async () => {
  const ask = loadBackground(tabs);
  const r = await ask({ cmd: "locate", page_url: "not a url" });
  assert.equal(r.ok, false);
  assert.match(r.error, /not a valid URL/);
});

test("inspect still refuses duplicate tabs instead of guessing", async () => {
  const ask = loadBackground(tabs);
  const r = await ask({ cmd: "inspect", page_url: "https://b.example/login" });
  assert.equal(r.ok, false);
  assert.match(r.error, /2 tabs are open/);
});

test("inspect still says when no tab matches", async () => {
  const ask = loadBackground(tabs);
  const r = await ask({ cmd: "inspect", page_url: "https://c.example/login" });
  assert.equal(r.ok, false);
  assert.match(r.error, /No open tab matches/);
});
