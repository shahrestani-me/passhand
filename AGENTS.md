# AGENTS.md

## Using Passhand as an agent

When a page asks for a username and password:

1. Call `fill_login` with the tab's current `page_url` and, whenever your browser tools give you one,
   its `tab_id`. Without `tab_id`, Passhand refuses if several tabs show the same URL.
2. If it reports several saved accounts, call it again with `username`.
3. After "Filled …", click the page's sign-in button yourself. Prefer that over `submit: true`.
4. Two-step logins (email page, then password page): call `fill_login` once on each page.
5. If it reports no saved login, tell the user to add one on Passhand's settings page (the Passhand
   icon in Chrome) or with `passhand add <site> <username>`. **Never ask the user to paste a password
   into the chat**, and never type one yourself. Don't open or use the settings page; managing logins
   is the user's job.
6. 2FA codes, passkeys, CAPTCHAs, sign-up and change-password forms are out of scope. Hand them back
   to the user.

`list_saved_logins` shows which sites and usernames exist and how each one fills: `auto` fills without
asking, `touch id` waits for the user to approve each fill, so it can't finish while they're away. It
never shows passwords.

## Working on this repository

Layout:

- `helper/`: Swift package, one binary with three roles: MCP server (`mcp`), Chrome native host
  (started with `chrome-extension://…` as its first argument), and CLI.
- `extension/`: Manifest V3 extension. `snapshotPage` and `fillPage` run inside the page and must
  stay self-contained. `options.html`/`options.js` is the settings page for managing logins; it only
  talks to the background worker, which forwards its requests to the helper.
- `tests/`: Node tests for the page-side field detection and filling (jsdom).

The rules in "Using Passhand as an agent" are also the MCP server's `instructions`
(`helper/Sources/passhand/MCPServer.swift`), which is all an agent outside this repository sees. Change
both together.

Build and test:

```bash
swift build -c release --package-path helper     # macOS only
cd tests && npm install && npm test
```

Invariants. Don't weaken these, and treat any change that touches them as security-sensitive:

- The password is never returned to the MCP client, printed, or logged.
- Logins are chosen by the tab's exact origin from Chrome, never by agent- or page-supplied text.
- https only (http only for local development hosts).
- A password is only written into `type=password` inputs, after validating every target first.
- The origin is re-checked right before writing.
- Duplicate tabs are refused, not guessed.
- Touch ID before every password fill unless the login is `auto`; enabling `auto` needs Touch ID.
- Only the extension's own settings page can manage logins, every change from it needs Touch ID
  (except turning `auto` off), and saved passwords are never sent back to it.
