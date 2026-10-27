// Several browsers running Passhand at once, with the real helper binary. Each fake browser starts the
// helper as Chrome would (a native host on stdio) and answers for the extension. Needs a built helper
// (swift build -c release --package-path helper, or PASSHAND_BIN); skipped without one.
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { once } from "node:events";

const bin = [
  process.env.PASSHAND_BIN,
  new URL("../helper/.build/release/passhand", import.meta.url).pathname,
  new URL("../helper/.build/debug/passhand", import.meta.url).pathname,
].find((p) => p && existsSync(p));
const skip = process.platform !== "darwin" || !bin ? "needs the helper built on macOS" : false;

// Short, so the socket paths stay under the Unix socket limit.
const dir = mkdtempSync("/tmp/passhand-test-");
const env = { ...process.env, PASSHAND_DIR: dir };
after(() => rmSync(dir, { recursive: true, force: true }));

const running = new Set();
after(() => { for (const b of running) b.process.kill("SIGKILL"); });

/// A browser with these tabs ({ id, url }) and its own Passhand helper.
async function startBrowser(name, tabs) {
  const child = spawn(bin, ["chrome-extension://test/"], { env, stdio: ["pipe", "pipe", "inherit"] });
  const browser = { name, process: child, inspected: [], socket: `${dir}/sockets/${child.pid}.sock` };
  running.add(browser);
  child.on("exit", () => running.delete(browser));

  let buffer = Buffer.alloc(0);
  child.stdout.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4 && buffer.length >= 4 + buffer.readUInt32LE(0)) {
      const length = buffer.readUInt32LE(0);
      const msg = JSON.parse(buffer.subarray(4, 4 + length).toString());
      buffer = buffer.subarray(4 + length);
      reply(msg);
    }
  });
  function reply(msg) {
    let answer;
    switch (msg.cmd) {
      case "ping":
        answer = { ok: true, pong: true };
        break;
      case "locate": {
        const byId = tabs.filter((t) => t.id === msg.tab_id && t.url === msg.page_url);
        const byUrl = tabs.filter((t) => t.url === msg.page_url);
        answer = byId.length ? { ok: true, by: "tab_id", count: 1 }
          : { ok: true, by: byUrl.length ? "url" : null, count: byUrl.length };
        break;
      }
      case "inspect":
        // Stop here: which browser got this far is all these tests need, and no Keychain item is read.
        browser.inspected.push(msg.page_url);
        answer = { ok: false, error: `reached ${name}` };
        break;
      default:
        answer = { ok: false, error: "unexpected " + msg.cmd };
    }
    const body = Buffer.from(JSON.stringify({ ...answer, id: msg.id }));
    const header = Buffer.alloc(4);
    header.writeUInt32LE(body.length);
    child.stdin.write(Buffer.concat([header, body]));
  }

  for (let i = 0; !existsSync(browser.socket); i++) {
    if (i > 200) throw new Error(`${name}'s helper never opened its socket`);
    await new Promise((r) => setTimeout(r, 10));
  }
  return browser;
}

async function close(browser) {
  browser.process.stdin.end(); // what Chrome does when it quits
  await once(browser.process, "exit");
}

async function run(args) {
  const child = spawn(bin, args, { env, stdio: ["ignore", "pipe", "inherit"] });
  let out = "";
  child.stdout.on("data", (d) => { out += d; });
  await once(child, "exit");
  return out;
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
  await close(chrome);
  await close(playwright);
});

test("the same page in two browsers is refused, not guessed", { skip }, async () => {
  const one = await startBrowser("one", [{ id: 1, url: A }]);
  const two = await startBrowser("two", [{ id: 2, url: A }]);
  assert.match(await fillLogin({ page_url: A }), /2 tabs are open on .* in 2 browsers/);
  // Tab ids are per browser, so the same id in both can't pick one either.
  const three = await startBrowser("three", [{ id: 1, url: A }]);
  assert.match(await fillLogin({ page_url: A, tab_id: 1 }), /in 2 browsers/);
  assert.deepEqual([one.inspected, two.inspected, three.inspected], [[], [], []]);
  await Promise.all([close(one), close(two), close(three)]);
});

test("a tab_id that only one browser has on that page picks that browser", { skip }, async () => {
  const one = await startBrowser("one", [{ id: 5, url: A }]);
  const two = await startBrowser("two", [{ id: 6, url: A }]);
  assert.equal(await fillLogin({ page_url: A, tab_id: 6 }), "reached two");
  assert.equal(await fillLogin({ page_url: A, tab_id: 5 }), "reached one");
  await Promise.all([close(one), close(two)]);
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
  assert.equal(existsSync(killed.socket), false, "its socket is cleared once nothing has that pid");
  assert.equal(existsSync(alive.socket), true);
  await close(alive);
});

test("doctor lists every browser running Passhand", { skip }, async () => {
  const one = await startBrowser("one", []);
  const two = await startBrowser("two", []);
  const out = await run(["doctor"]);
  for (const b of [one, two]) {
    assert.match(out, new RegExp(`helper pid ${b.process.pid}\\): running, extension answering ✓`));
  }
  await Promise.all([close(one), close(two)]);
});
