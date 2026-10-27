// Tests for the page-side code of the extension (snapshotPage / fillPage) in jsdom.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const source = readFileSync(new URL("../extension/background.js", import.meta.url), "utf8");
// Only the functions that run inside the page; the service-worker part needs chrome.* APIs.
const MARKER = "// ---------- Runs inside the page";
const pageCode = source.slice(source.indexOf(MARKER));

function load(html, url = "https://example.com/login") {
  const dom = new JSDOM(html, { url, runScripts: "outside-only" });
  const w = dom.window;
  // jsdom has no layout; treat elements as visible unless marked otherwise.
  w.HTMLElement.prototype.getBoundingClientRect = function () {
    return this.hasAttribute("data-zero") ? { width: 0, height: 0 } : { width: 200, height: 30 };
  };
  w.CSS = { escape: (s) => String(s) };
  w.eval(pageCode);
  return w;
}

// Objects created inside jsdom belong to another realm; compare plain copies.
const plain = (o) => JSON.parse(JSON.stringify(o));
const guess = (html) => plain(load(html).snapshotPage().guess);

test("classic email + password form", () => {
  assert.deepEqual(guess(`<form><input name=email type=email><input type=password></form>`),
    { username_ref: "f1", password_ref: "f2" });
});

test("autocomplete hints win over a search box", () => {
  assert.deepEqual(
    guess(`<form><input name=q placeholder=Search><input autocomplete=username><input type=password autocomplete=current-password></form>`),
    { username_ref: "f2", password_ref: "f3" });
});

test("invisible honeypot fields are ignored", () => {
  const w = load(`<form><input name=user data-zero><input name=login><input type=password></form>`);
  const s = w.snapshotPage();
  assert.equal(s.fields.length, 2);
  assert.equal(w.document.querySelector("[data-cv-ref=f1]").name, "login");
});

test("email-first page: username only", () => {
  assert.deepEqual(guess(`<form><label for=i>Email or phone</label><input id=i></form>`),
    { username_ref: "f1", password_ref: null });
});

test("password-only page", () => {
  assert.deepEqual(guess(`<form><input type=password autocomplete=current-password></form>`),
    { username_ref: null, password_ref: "f1" });
});

test("change-password form is not guessed", () => {
  assert.deepEqual(guess(`<form><input type=password><input type=password></form>`),
    { username_ref: null, password_ref: null });
});

test("page with only a search box finds nothing", () => {
  assert.deepEqual(guess(`<input name=q placeholder="Search docs">`), { username_ref: null, password_ref: null });
});

test("fill writes values and fires input events", () => {
  const w = load(`<form><input name=email type=email><input type=password></form>`);
  const g = w.snapshotPage().guess;
  let inputEvents = 0;
  w.document.querySelector("input[type=password]").addEventListener("input", () => inputEvents++);
  const r = w.fillPage("https://example.com", [
    { ref: g.username_ref, kind: "username", value: "user@example.com" },
    { ref: g.password_ref, kind: "password", value: "not-a-real-password" },
  ], false);
  assert.equal(r.ok, true);
  assert.deepEqual(plain(r.filled), ["username", "password"]);
  assert.equal(w.document.querySelector("[name=email]").value, "user@example.com");
  assert.equal(inputEvents, 1);
  assert.equal(JSON.stringify(r).includes("not-a-real-password"), false, "result must never echo values");
});

test("fill refuses a different origin", () => {
  const w = load(`<form><input type=password></form>`);
  const g = w.snapshotPage().guess;
  const r = w.fillPage("https://evil.example", [{ ref: g.password_ref, kind: "password", value: "x" }], false);
  assert.equal(r.ok, false);
  assert.equal(w.document.querySelector("input").value, "");
});

test("fill refuses to put a password into a text field and leaves the form untouched", () => {
  const w = load(`<form><input name=email type=email><input type=password></form>`);
  const g = w.snapshotPage().guess;
  const r = w.fillPage("https://example.com", [
    { ref: g.password_ref, kind: "password", value: "ok" },
    { ref: g.username_ref, kind: "password", value: "leak" },
  ], false);
  assert.equal(r.ok, false);
  assert.equal(w.document.querySelector("[name=email]").value, "");
  assert.equal(w.document.querySelector("input[type=password]").value, "", "nothing filled when any item is invalid");
});
