// Passhand settings page: the logins AI agents may use, grouped by site.
// It only talks to Passhand's background worker, which forwards to the helper. The helper asks for
// Touch ID before every change. Saved passwords never come back to this page.

const form = document.getElementById("add");
const list = document.getElementById("logins");
const statusLine = document.getElementById("status");

async function ask(message) {
  let reply;
  try {
    reply = await chrome.runtime.sendMessage(message);
  } catch (e) {
    throw new Error("Passhand's background worker didn't answer. Reload the extension and this page.");
  }
  if (!reply || !reply.ok) throw new Error((reply && reply.error) || "No answer from Passhand.");
  return reply;
}

function setStatus(text, kind = "") {
  statusLine.textContent = text;
  statusLine.className = kind;
}

// One request at a time: a Touch ID prompt may be waiting on the Mac.
function setBusy(busy) {
  document.querySelectorAll("button, input").forEach((el) => { el.disabled = busy; });
}

async function run(message, waitingText, doneText) {
  setBusy(true);
  setStatus(waitingText);
  try {
    const reply = await ask(message);
    setStatus(doneText(reply), "ok");
    return reply;
  } catch (e) {
    setStatus(e.message, "error");
    return null;
  } finally {
    setBusy(false);
  }
}

async function refresh() {
  try {
    const { logins } = await ask({ cmd: "logins.list" });
    render(logins || []);
  } catch (e) {
    list.replaceChildren(el("p", { className: "empty" }, "Couldn't load your logins."));
    setStatus(e.message, "error");
  }
}

// Builds elements with textContent only, so a site or username can never inject markup.
function el(tag, props = {}, ...children) {
  const node = Object.assign(document.createElement(tag), props);
  node.append(...children);
  return node;
}

function render(logins) {
  if (!logins.length) {
    list.replaceChildren(el("p", { className: "empty" },
      "No logins saved yet. Agents can't sign in anywhere until you add one."));
    return;
  }
  const bySite = new Map();
  for (const login of logins) {
    if (!bySite.has(login.origin)) bySite.set(login.origin, []);
    bySite.get(login.origin).push(login);
  }
  list.replaceChildren(...[...bySite].map(([origin, accounts]) => {
    const addAnother = el("button", { type: "button", textContent: "Add another account" });
    addAnother.addEventListener("click", () => {
      form.elements.site.value = origin;
      form.elements.username.value = "";
      form.elements.password.value = "";
      form.elements.username.focus();
    });
    return el("div", { className: "site" },
      el("div", { className: "site-head" }, el("span", { className: "origin" }, origin), addAnother),
      ...accounts.map(account));
  }));
}

function account(login) {
  const auto = el("input", { type: "checkbox", checked: login.auto });
  auto.addEventListener("change", async () => {
    const wanted = auto.checked;
    auto.checked = !wanted; // show the real state until the helper confirms
    const done = await run(
      { cmd: "logins.auto", origin: login.origin, username: login.username, auto: wanted },
      wanted ? "Confirm with Touch ID on your Mac…" : "Saving…",
      () => `${login.username} on ${login.origin} ${wanted ? "now fills without Touch ID" : "asks for Touch ID again"}.`);
    if (done) await refresh();
  });

  const remove = el("button", { type: "button", className: "danger", textContent: "Remove" });
  remove.addEventListener("click", async () => {
    const done = await run(
      { cmd: "logins.remove", origin: login.origin, username: login.username },
      "Confirm with Touch ID on your Mac…",
      () => `Removed ${login.username} from ${login.origin}.`);
    if (done) await refresh();
  });

  return el("div", { className: "account" },
    el("span", { className: "user" }, login.username),
    el("label", { className: "check" }, auto, "Auto"),
    remove);
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const f = form.elements;
  const reply = await run(
    { cmd: "logins.save", site: f.site.value.trim(), username: f.username.value.trim(),
      password: f.password.value, auto: f.auto.checked },
    "Confirm with Touch ID on your Mac…",
    (r) => `${r.replaced ? "Replaced the password for" : "Saved"} ${r.username} on ${r.origin}` +
      (r.auto ? ", fills without Touch ID." : ", asks for Touch ID on each fill."));
  if (reply) {
    // Keep the site, so adding a second account for it is quick.
    f.username.value = "";
    f.password.value = "";
    f.auto.checked = false;
    await refresh();
  }
});

refresh();
