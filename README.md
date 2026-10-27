# Passhand

**Passhand hands your password to the page, never to the agent.**

It lets AI agents (or any automation) sign in to websites without ever seeing your passwords.

Your agent drives the browser as usual. When it reaches a login page it calls one MCP tool,
`fill_login`. A small helper on your computer looks the login up in your **macOS Keychain** or
**Windows Credential Manager** by the tab's real origin and fills the fields **directly in the page**. The agent gets back "filled" or an error.
The password never enters the model's context, its logs, or the AI provider's servers.

> Status: early. macOS or Windows, with Google Chrome. Tested with Claude in Chrome driven from Claude
> desktop on macOS; Windows support is new. Any MCP client that can also drive Chrome can use it.

### Where it works

Passhand works with agents that run on your computer and can use MCP tools, such as:

- **Claude desktop** (with Claude in Chrome connected)
- **Claude Code**
- other MCP clients that also drive Chrome

**It does not work from the Claude side panel inside Chrome** (the chat you open from the Claude
extension's icon). That panel can't use tools installed on your computer, so it can't reach Passhand. If you
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
                                                                                   │ Touch ID / Windows Hello (unless "auto")
                                                                                   │ Keychain / Credential Manager lookup by origin
                                                                                   ▼
                                         page ◄── fills fields ◄── Passhand Chrome extension
```

| Part | What it is | Sees the password? |
|---|---|---|
| `helper/` | One Swift binary: MCP server (`passhand mcp`), Chrome native-messaging host, and CLI | Only the native host reads it from the Keychain (or Credential Manager) |
| `extension/` | Manifest V3 extension: finds the tab, reads its real origin, finds the fields, fills them | Receives it only to write it into the field |
| The agent / model | Calls `fill_login`, then clicks "Sign in" itself | **No.** Only gets a status string |

### Rules enforced in code

- **Exact-origin match.** The login is chosen by the tab's real origin as Chrome reports it, never by
  text from the agent or the page. A look-alike domain has no saved login, so nothing is filled.
- **https only** (plain http only for `localhost`, `*.localhost` and `*.test`).
- **A password only goes into an `<input type="password">`** on that origin, whatever picked the field.
- **The origin is checked again right before writing**, so a redirect mid-fill aborts.
- **No guessing between tabs.** If several tabs show the same URL and no `tab_id` is given, it refuses.
- **Touch ID before every password fill** (Windows Hello on Windows), unless you marked that login `auto`
  (which itself needs Touch ID or Windows Hello).
- **Main frame only.** Logins inside cross-origin iframes are not filled.
- Field detection uses page heuristics (`autocomplete`, `type=password`, the field before it). An
  optional **local** model (Ollama) helps with odd forms. It sees field names and labels only, never values.

## Install

### macOS

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

### Windows

Requires Windows 10 or 11 with Windows Hello set up (a PIN is enough: **Settings → Accounts →
Sign-in options**), Google Chrome, and the [Swift toolchain for Windows](https://www.swift.org/install/windows/)
(its instructions include the Visual Studio build tools it needs). Open a new PowerShell window after
installing Swift, then:

```powershell
git clone https://github.com/shahrestani-me/passhand.git
cd passhand
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Then:

1. **Chrome:** open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked**, paste
   the folder path the installer copied to your clipboard (`%LOCALAPPDATA%\passhand\extension`) into
   the folder box, and click **Select Folder**. The ID must be `alpckagkehodlliniailejachglpeinb`.
2. **Your MCP client:** the installer registers Passhand with Claude desktop. Quit it completely (also
   from the system tray) and reopen it. For other clients, add a stdio server running
   `%LOCALAPPDATA%\passhand\bin\passhand.exe mcp`.
3. **Check:** open a new terminal and run `passhand doctor`.

> The `key` in `extension/manifest.json` is a **public** key. It only pins the extension ID so the
> native host can trust it. No private key is needed or included.

## Updating

```bash
cd passhand
git pull
./install.sh                                               # macOS
powershell -ExecutionPolicy Bypass -File .\install.ps1     # Windows
```

Then open `chrome://extensions` and click the reload arrow on the Passhand card. Chrome only picks up
the new extension files and starts the new helper after a reload; until then `passhand doctor` reports
the Chrome helper as not reachable. Restart Claude desktop too, so it loads the new MCP server. Saved
logins stay in your Keychain (or Credential Manager).

## Use

### Settings page

Click the **Passhand** icon in Chrome's toolbar (or open the extension's **Options**) to manage logins
without Terminal:

- Saved logins are grouped by site, and a site can hold several accounts. Agents can only sign in to the
  sites and accounts listed there.
- **Add a login** saves a site, username and password to your Keychain (Credential Manager on
  Windows). Saving an existing site and username replaces its password.
- Each account has an **Auto** switch and a **Remove** button.
- Every change asks for Touch ID on your Mac, or Windows Hello on Windows (turning Auto off doesn't need
  it). Saved passwords are
  never shown again.

The page and the commands below edit the same saved logins, so use whichever you prefer.

### Terminal

```bash
passhand add github.com you@example.com                 # asks for the password (not echoed)
passhand add staging.myapp.com qa@example.com --auto    # test account: fills without Touch ID / Windows Hello
passhand auto staging.myapp.com qa@example.com off      # back to Touch ID / Windows Hello
passhand list                                           # sites, usernames, fill mode (never passwords)
passhand remove github.com you@example.com
passhand doctor
```

Then ask your agent to log in somewhere. It navigates, calls `fill_login`, and clicks "Sign in".

### Unattended logins (test and QA accounts)

Logins marked `auto` fill with no prompt, so an agent can run login flows while you're away. Turning
`auto` on requires Touch ID (Windows Hello on Windows), so an agent with shell access can't enable it
silently. Keep `auto` for
test accounts; leave personal accounts on Touch ID.

For unattended runs: stay logged in to macOS (screen lock is fine), keep the Mac awake
(`caffeinate -dimsu &`), and keep Chrome open with the extension enabled. After each install, do one
attended fill: macOS may ask once whether `passhand` may read its Keychain items. Click
**Always Allow**. The installer signs the binary with your Apple Development certificate when it finds
one, which keeps that permission across rebuilds.

On Windows: stay signed in (a locked screen is fine), keep the PC from sleeping, and keep Chrome open
with the extension enabled.

### MCP tools

| Tool | Arguments | Returns |
|---|---|---|
| `fill_login` | `page_url` (required), `tab_id` (recommended), `username`, `submit` | "Filled the username and password for … on …" or an error |
| `list_saved_logins` | — | Sites, usernames and fill mode (`auto`, or `touch id` / `windows hello`), never passwords |

The MCP server gives connected agents its usage rules automatically. They are the same rules as in
[AGENTS.md](AGENTS.md).

### Try it safely

Use a public practice site such as `https://the-internet.herokuapp.com/login`, which shows its own
demo credentials on the page. Save them with `passhand add the-internet.herokuapp.com <demo user>`
and ask your agent to log in.

## Troubleshooting

Start with `passhand doctor`. It checks the helper, your saved logins, Chrome, Claude desktop, Touch ID or
Windows Hello, and the optional local model.

| What you see | What to do |
|---|---|
| `doctor`: Chrome helper not reachable | Open Chrome, check Passhand is enabled on `chrome://extensions`, and click its reload arrow. Always needed after `./install.sh`. |
| `doctor`: running, but the extension did not answer | Reload the extension, and check its ID is `alpckagkehodlliniailejachglpeinb`. |
| The agent has no `fill_login` tool | Restart Claude desktop after installing. For other MCP clients, add the stdio server (see [Install](#install)). The Claude side panel in Chrome can't use it (see [Where it works](#where-it-works)). |
| "No saved login for https://…" | Add one on the settings page or with `passhand add`. Origins are exact: `www.` and other subdomains are separate entries. `passhand list` shows what's saved. |
| "N tabs are open on …, so nothing was filled" | The agent should pass `tab_id`. Otherwise close the duplicate tabs. |
| "No open tab matches …" | `page_url` must be the tab's URL as it is open now, after any redirects. |
| "Couldn't find a login form on this page" | Make sure the form is visible (for example, open the sign-in dialog first), then try again. Logins inside cross-origin iframes aren't supported. For unusual forms, the optional local model can help (see [Configuration](#configuration-optional)). |
| "Touch ID was not confirmed, so nothing was filled." | The prompt was declined, or left open for 90 seconds. Try again. |
| Windows: "Windows Hello was not confirmed …" but you saw no prompt | The prompt can open behind other windows. Look for it on the taskbar, then try again. |
| Windows: `doctor` says Windows Hello is unavailable | Set up a PIN, fingerprint or face in **Settings → Accounts → Sign-in options**. |
| Windows: `install.ps1` says Swift isn't found | Install the Swift toolchain, then open a new terminal so it's on your PATH. |
| Windows: the agent has no `fill_login` tool | Quit Claude desktop from the system tray, not just its window, and reopen it. If it still doesn't appear, add the server in Claude's **Settings → Developer → Edit Config** (see [Install](#windows)). |
| macOS asks whether `passhand` may use a Keychain item | Click **Always Allow**. Without an Apple Development certificate this comes back after every rebuild. |
| An `auto` login doesn't fill while you're away | Stay logged in to macOS, keep the Mac awake (`caffeinate -dimsu &`), and keep Chrome open with the extension enabled. |
| "Refusing to fill on http://…" | Only https pages are filled. Plain http works only for `localhost`, `*.localhost` and `*.test`. |

## Limitations

- macOS and Windows, Chrome only. Linux isn't supported yet.
- On Windows, Credential Manager lets any program running as you read saved passwords, without the
  prompt the macOS Keychain shows. See [SECURITY.md](SECURITY.md).
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
- Linux (Secret Service)
- Per-login allowlists of which agents or clients may trigger fills

## Configuration (optional)

`~/Library/Application Support/passhand/config.json` (Windows: `%LOCALAPPDATA%\passhand\config.json`)

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

On Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1           # keeps saved logins in Credential Manager
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -Purge    # deletes them too
```

## License

[MIT](LICENSE)
