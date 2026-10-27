# Passhand

**Passhand hands your password to the page, never to the agent.**

It lets AI agents (or any automation) sign in to websites without ever seeing your passwords.

Your agent drives the browser as usual. When it reaches a login page it calls one MCP tool,
`fill_login`. A small helper on your Mac looks the login up in your **macOS Keychain** by the tab's
real origin and fills the fields **directly in the page**. The agent gets back "filled" or an error.
The password never enters the model's context, its logs, or the AI provider's servers.

> Status: early. macOS + Google Chrome. Tested with Claude in Chrome driven from Claude desktop.
> Any MCP client that can also drive Chrome can use it.

### Where it works

Passhand works with agents that run on your Mac and can use MCP tools, such as:

- **Claude desktop** (with Claude in Chrome connected)
- **Claude Code**
- other MCP clients that also drive Chrome

**It does not work from the Claude side panel inside Chrome** (the chat you open from the Claude
extension's icon). That panel can't use tools installed on your Mac, so it can't reach Passhand. If you
ask it to log in, it will say it doesn't have the password. Ask from Claude desktop or Claude Code
instead.

---

## Why this exists

Browser agents are now good enough to test web apps, run QA flows and work through admin panels.
Sooner or later every one of those tasks hits a login page, and today there are three bad options:

1. **Paste the password into the chat.** It lands in the model's context, in conversation history,
   in logs, and on the provider's side. A prompt-injected page can ask the agent to type it
   somewhere else.
2. **Give the agent a password-manager tool that returns secrets.** Same problem: the secret is in
   the context window as soon as the tool returns it.
3. **Sit next to the machine and type it yourself.** Safe, but it defeats the point of an agent,
   especially for test runs while you're away.

Existing solutions each cover part of this:

- Some agentic-autofill offerings (e.g. 1Password's, built with Browserbase) inject credentials
  without the model seeing them, but they work in specific **cloud browsers** and ask a human to
  approve each request.
- Open-source MCP credential routers fill over the **Chrome DevTools Protocol**. That needs a Chrome
  launched in remote-debugging mode, often Docker and a self-hosted vault. Recent Chrome versions
  restrict remote debugging on your normal profile, so these don't work in the browser you're
  actually signed in to.
- Agent frameworks (e.g. browser-use's sensitive-data placeholders) solve it inside their own
  framework only.

**The gap:** a local, inspectable component that lets *any* MCP agent log in **in your real Chrome
profile**, using the **OS keychain** you already trust, never revealing the secret to the model, and
able to run **unattended for test accounts you explicitly opt in**.

Passhand is that component, and it's open source because a tool that touches your passwords should
be something you can read end to end.

## How it works

```
Agent ──fill_login(page_url, tab_id)──► MCP helper ──(local socket, no secrets)──► native host
                                                                                   │ Touch ID (unless "auto")
                                                                                   │ Keychain lookup by origin
                                                                                   ▼
                                         page ◄── fills fields ◄── Passhand Chrome extension
```

| Part | What it is | Sees the password? |
|---|---|---|
| `helper/` | One Swift binary: MCP server (`passhand mcp`), Chrome native-messaging host, and CLI | Only the native host reads it from the Keychain |
| `extension/` | Manifest V3 extension: finds the tab, reads its real origin, finds the fields, fills them | Receives it only to write it into the field |
| The agent / model | Calls `fill_login`, then clicks "Sign in" itself | **No.** Only gets a status string |

### Rules enforced in code

- **Exact-origin match.** The login is chosen by the tab's real origin as Chrome reports it, never by
  text from the agent or the page. A look-alike domain has no saved login, so nothing is filled.
- **https only** (plain http only for `localhost`, `*.localhost` and `*.test`).
- **A password only goes into an `<input type="password">`** on that origin, whatever picked the field.
- **The origin is checked again right before writing**, so a redirect mid-fill aborts.
- **No guessing between tabs.** If several tabs show the same URL and no `tab_id` is given, it refuses.
- **Touch ID before every password fill**, unless you marked that login `auto` (which itself needs Touch ID).
- **Main frame only.** Logins inside cross-origin iframes are not filled.
- Field detection uses page heuristics (`autocomplete`, `type=password`, the field before it). An
  optional **local** model (Ollama) helps with odd forms. It sees field names and labels only, never values.

## Install

Requires macOS 13+, Xcode or the command line tools, and Google Chrome.

```bash
git clone https://github.com/shahrestani-me/passhand.git
cd passhand
./install.sh
```

Then:

1. **Chrome:** open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked**, and
   select the folder the installer copied to your clipboard (press ⇧⌘G, paste). Load it into the same
   Chrome profile your agent uses. The ID must be `alpckagkehodlliniailejachglpeinb`.
2. **Your MCP client:** the installer registers Passhand with Claude desktop. Restart it. For other
   clients, add a stdio server running `~/Library/Application Support/passhand/bin/passhand mcp`.
3. **Check:** `passhand doctor`

> The `key` in `extension/manifest.json` is a **public** key. It only pins the extension ID so the
> native host can trust it. No private key is needed or included.

## Use

### Settings page

Click the **Passhand** icon in Chrome's toolbar (or open the extension's **Options**) to manage logins
without Terminal:

- Saved logins are grouped by site, and a site can hold several accounts. Agents can only sign in to the
  sites and accounts listed there.
- **Add a login** saves a site, username and password to your Keychain. Saving an existing site and
  username replaces its password.
- Each account has an **Auto** switch and a **Remove** button.
- Every change asks for Touch ID on your Mac (turning Auto off doesn't need it). Saved passwords are
  never shown again.

The page and the commands below edit the same Keychain items, so use whichever you prefer.

### Terminal

```bash
passhand add github.com you@example.com                 # asks for the password (not echoed)
passhand add staging.myapp.com qa@example.com --auto    # test account: fills without Touch ID
passhand auto staging.myapp.com qa@example.com off      # back to Touch ID
passhand list                                           # sites, usernames, fill mode (never passwords)
passhand remove github.com you@example.com
passhand doctor
```

Then ask your agent to log in somewhere. It navigates, calls `fill_login`, and clicks "Sign in".

### Unattended logins (test and QA accounts)

Logins marked `auto` fill with no prompt, so an agent can run login flows while you're away. Turning
`auto` on requires Touch ID, so an agent with shell access can't enable it silently. Keep `auto` for
test accounts; leave personal accounts on Touch ID.

For unattended runs: stay logged in to macOS (screen lock is fine), keep the Mac awake
(`caffeinate -dimsu &`), and keep Chrome open with the extension enabled. After each install, do one
attended fill: macOS may ask once whether `passhand` may read its Keychain items. Click
**Always Allow**. The installer signs the binary with your Apple Development certificate when it finds
one, which keeps that permission across rebuilds.

### MCP tools

| Tool | Arguments | Returns |
|---|---|---|
| `fill_login` | `page_url` (required), `tab_id` (recommended), `username`, `submit` | "Filled the username and password for … on …" or an error |
| `list_saved_logins` | — | Sites and usernames, never passwords |

See [AGENTS.md](AGENTS.md) for how agents should use them.

### Try it safely

Use a public practice site such as `https://the-internet.herokuapp.com/login`, which shows its own
demo credentials on the page. Save them with `passhand add the-internet.herokuapp.com <demo user>`
and ask your agent to log in.

## Limitations

- macOS and Chrome only for now.
- Not usable from the Claude side panel in Chrome; use Claude desktop or Claude Code
  (see [Where it works](#where-it-works)).
- Not handled: 2FA codes, passkeys, CAPTCHAs, sign-up and change-password forms, logins in
  cross-origin iframes. Agents should hand those back to you.
- Exact origins: `github.com` and `www.github.com` are different entries.
- Once filled, the page's own JavaScript can read the field. That's inherent to any autofill,
  including your browser's own.

See [SECURITY.md](SECURITY.md) for the full threat model.

## Roadmap

- Chrome Web Store listing, plus a signed and notarized helper installer (`.pkg` or Homebrew)
- TOTP support for 2FA test accounts
- Linux (Secret Service) and Windows (Credential Manager)
- Per-login allowlists of which agents or clients may trigger fills

## Configuration (optional)

`~/Library/Application Support/passhand/config.json`

```json
{ "model": "qwen2.5:3b", "ollama_url": "http://127.0.0.1:11434", "model_fallback": true }
```

The local model is only used when the heuristics find nothing. Set `model_fallback` to `false` to
never use it.

## Uninstall

```bash
./uninstall.sh            # keeps saved logins in the Keychain
./uninstall.sh --purge    # deletes them too
```

## License

[MIT](LICENSE)
