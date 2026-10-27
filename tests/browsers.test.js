// Several browsers running Passhand at once, with the real helper binary. Each fake browser starts the
// helper as Chrome would (a native host on stdio) and runs the real extension worker (background.js)
// against it, with Chrome's tabs faked. Needs a built helper (swift build -c release --package-path
// helper, or PASSHAND_BIN); skipped without one.
import { test, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { once } from "node:events";
import vm from "node:vm";

const bin = [
  process.env.PASSHAND_BIN,
  new URL("../helper/.build/release/passhand", import.meta.url).pathname,
  new URL("../helper/.build/debug/passhand", import.meta.url).pathname,
].find((p) => p && existsSync(p));
const skip = process.platform !== "darwin" || !bin ? "needs the helper built on macOS" : false;
const extension = readFileSync(new URL("../extension/background.js", import.meta.url), "utf8");

// Short, so the socket paths stay under the Unix socket limit.
const dir = mkdtempSync("/tmp/passhand-test-");
const env = { ...process.env, PASSHAND_DIR: dir };
after(() => rmSync(dir, { recursive: true, force: true }));

const running = new Set();
async function stopAll() {
  await Promise.all([...running].map((b) => { b.process.kill("SIGKILL"); return once(b.process, "exit"); }));
}
beforeEach(stopAll); // a failed test can leave its browsers running
after(stopAll);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/// A browser with these tabs ({ id, url }) and its own Passhand helper.
///   hang: the extension never answers "locate"
///   slow: it answers "locate" after this many ms
///   quitAfterLocate: the browser quits right after answering "locate"
async function startBrowser(name, tabs, { hang = false, slow = 0, quitAfterLocate = false } = {}) {
  const child = spawn(bin, ["chrome-extension://test/"], { env, stdio: ["pipe", "pipe", "inherit"] });
  const browser = { name, process: child, inspected: [] };
  running.add(browser);
  child.on("exit", () => running.delete(browser));

  // The native port is the helper's stdio, in Chrome's framing.
  const listeners = {};
  const on = (n) => ({ addListener: (fn) => { listeners[n] = fn; } });
  const quitAfter = new Set();
  const port = {
    postMessage(message) {
      const body = Buffer.from(JSON.stringify(message));
      const header = Buffer.alloc(4);
      header.writeUInt32LE(body.length);
      child.stdin.write(Buffer.concat([header, body]));
      // Quit once the helper has passed the answer on, as Chrome does when it quits.
      if (quitAfter.has(message.id)) setTimeout(() => child.stdin.end(), 100);
    },
    onMessage: on("message"),
    onDisconnect: on("disconnect"),
  };
  const chrome = {
    runtime: {
      id: "test",
      getURL: (p) => `chrome-extension://test/${p}`,
      connectNative: () => port,
      onStartup: on("startup"),
      onInstalled: on("installed"),
      onMessage: on("runtime.message"),
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
    scripting: {
      // Stop at reading the page: which browser got this far is all these tests need, and no Keychain
      // item is read.
      executeScript: async ({ target }) => {
        browser.inspected.push(tabs.find((t) => t.id === target.tabId).url);
        throw new Error(`reached ${name}`);
      },
    },
  };
  vm.runInNewContext(extension, { chrome, console, crypto, setTimeout, clearTimeout, URL, structuredClone });

  let buffer = Buffer.alloc(0);
  child.stdout.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4 && buffer.length >= 4 + buffer.readUInt32LE(0)) {
      const length = buffer.readUInt32LE(0);
      const message = JSON.parse(buffer.subarray(4, 4 + length).toString());
      buffer = buffer.subarray(4 + length);
      if (message.cmd === "locate") {
        if (hang) continue;
        if (quitAfterLocate) quitAfter.add(message.id);
        setTimeout(() => listeners.message(message), slow);
      } else {
        listeners.message(message);
      }
    }
  });

  for (let i = 0; !browser.socket; i++) {
    if (i > 200) throw new Error(`${name}'s helper never opened its socket`);
    const files = existsSync(`${dir}/sockets`) ? readdirSync(`${dir}/sockets`) : [];
    const file = files.find((f) => f.startsWith(`${child.pid}-`) && f.endsWith(".sock"));
    if (file) browser.socket = `${dir}/sockets/${file}`;
    else await sleep(10);
  }
  return browser;
}

async function close(browser) {
  browser.process.stdin.end(); // what Chrome does when it quits
  await once(browser.process, "exit");
}

/// Calls fill_login through `passhand mcp`, as an agent would, and returns the tool's text.
async function fillLogin(args) {
  const mcp = spawn(bin, ["mcp"], { env, stdio: ["pipe", "pipe", "inherit"] });
  const call = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "fill_login", arguments: args } };
  mcp.stdin.write(JSON.stringify(call) + "\n");
  let out = "";
  for await (const chunk of mcp.stdout) {
    out += chunk;
    if (out.includes("\n")) break;
  }
  mcp.stdin.end(); // like a client going away; the MCP server exits
  return JSON.parse(out.split("\n")[0]).result.content[0].text;
}

const A = "https://a.example/login";
const B = "https://b.example/login";

test("fill_login goes to the browser that has the tab, in both directions", { skip }, async () => {
  const chrome = await startBrowser("Chrome", [{ id: 1, url: A }]);
  const playwright = await startBrowser("Playwright", [{ id: 1, url: B }]);
  assert.equal(await fillLogin({ page_url: A }), "reached Chrome");
  assert.equal(await fillLogin({ page_url: B }), "reached Playwright");
  assert.deepEqual(chrome.inspected, [A]);
  assert.deepEqual(playwright.inspected, [B]);
  await Promise.all([close(chrome), close(playwright)]);
});

test("the same page in two browsers is refused, however each one matches", { skip }, async () => {
  const cases = [
    ["the same URL", [{ id: 1, url: A }], [{ id: 2, url: A }], {}],
    // Tab ids are per browser: a tab_id match in one doesn't rule out the other.
    ["a tab_id in one, the URL in the other", [{ id: 6, url: A }], [{ id: 9, url: A }], { tab_id: 6 }],
    ["the same tab_id in both", [{ id: 1, url: A }], [{ id: 1, url: A }], { tab_id: 1 }],
    ["the exact URL in one, the same path in the other", [{ id: 1, url: A }], [{ id: 1, url: A + "?next=/home" }], {}],
  ];
  for (const [what, tabsOne, tabsTwo, extra] of cases) {
    const one = await startBrowser("one", tabsOne);
    const two = await startBrowser("two", tabsTwo);
    assert.match(await fillLogin({ page_url: A, ...extra }), /is open in 2 browsers \(\S+ \(helper pid \d+\), \S+ \(helper pid \d+\)\)/, what);
    assert.deepEqual([one.inspected, two.inspected], [[], []], what);
    await Promise.all([close(one), close(two)]);
  }
});

test("a browser that doesn't answer blocks the fill instead of being skipped", { skip }, async () => {
  const one = await startBrowser("one", [{ id: 1, url: A }]);
  const silent = await startBrowser("silent", [{ id: 1, url: A }], { hang: true });
  assert.match(await fillLogin({ page_url: A }), /^Nothing was filled: Passhand in a browser \(helper pid \d+\) didn't answer/);
  assert.deepEqual(one.inspected, []);
  await Promise.all([close(one), close(silent)]);
});

test("a browser that quits between finding the tab and filling it is named as such", { skip }, async () => {
  const quitting = await startBrowser("quitting", [{ id: 1, url: A }], { quitAfterLocate: true });
  const other = await startBrowser("other", [{ id: 1, url: B }], { slow: 300 });
  assert.match(await fillLogin({ page_url: A }), /^\S+ \(helper pid \d+\) closed before the login could be filled/);
  await close(other);
});

test("a page no browser has open is reported as such", { skip }, async () => {
  const one = await startBrowser("one", [{ id: 1, url: A }]);
  const two = await startBrowser("two", [{ id: 1, url: B }]);
  assert.match(await fillLogin({ page_url: "https://c.example/login" }), /No open tab matches .* in any browser/);
  await Promise.all([close(one), close(two)]);
});

for (const closing of ["first", "second"]) {
  test(`closing the ${closing} browser leaves Passhand working in the other`, { skip }, async () => {
    const first = await startBrowser("first", [{ id: 1, url: A }]);
    const second = await startBrowser("second", [{ id: 1, url: B }]);
    const [gone, left, url] = closing === "first" ? [first, second, B] : [second, first, A];
    await close(gone);
    assert.equal(existsSync(gone.socket), false, "the closed browser's helper removes its own socket");
    assert.equal(existsSync(left.socket), true, "and leaves the other's alone");
    assert.equal(await fillLogin({ page_url: url }), `reached ${left.name}`);
    await close(left);
  });
}

test("a helper that was killed outright doesn't get in the way", { skip }, async () => {
  const alive = await startBrowser("alive", [{ id: 1, url: A }]);
  const killed = await startBrowser("killed", [{ id: 1, url: A }]);
  killed.process.kill("SIGKILL");
  await once(killed.process, "exit");
  assert.equal(existsSync(killed.socket), true, "a killed helper can't clean up");
  assert.equal(await fillLogin({ page_url: A }), "reached alive");
  assert.equal(existsSync(killed.socket), false, "its socket is cleared, since nothing listens on it");
  assert.equal(existsSync(alive.socket), true);
  await close(alive);
});

test("doctor lists every browser running Passhand", { skip }, async () => {
  const one = await startBrowser("one", []);
  const two = await startBrowser("two", []);
  const doctor = spawn(bin, ["doctor"], { env, stdio: ["ignore", "pipe", "inherit"] });
  let out = "";
  doctor.stdout.on("data", (d) => { out += d; });
  await once(doctor, "exit");
  for (const b of [one, two]) {
    assert.match(out, new RegExp(`\\(helper pid ${b.process.pid}\\): running, extension answering ✓`));
  }
  await Promise.all([close(one), close(two)]);
});
