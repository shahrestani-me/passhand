# Security

Passhand handles passwords, so this file says plainly what it protects against and what it doesn't.

## What Passhand protects

| Threat | How it's handled |
|---|---|
| The password ending up in the model's context, chat history, logs or the AI provider | The agent never receives it. The MCP process never reads it either; only the native host started by Chrome does, and it sends it straight to the page. |
| A phishing or look-alike page getting your password | Logins are matched by the exact origin Chrome reports for the tab. A different origin has no saved login. |
| A prompt-injected page convincing the agent to fill the password somewhere else | The agent only passes a URL and tab id. Which password is used, and where it can go, is decided by the tab's real origin. |
| A page tricking the filler into a visible text field or search box | A password is only written into an `<input type="password">`, validated before anything is filled. |
| A redirect between "inspect" and "fill" | The origin is checked again in Chrome and inside the page right before writing. |
| Filling the wrong tab when several show the same page | With no `tab_id`, duplicates are refused instead of guessed. |
| Another local user or process talking to the helper | The socket is `0600` inside a `0700` folder, and the peer's uid is checked. |
| An agent with shell access silently enabling unattended fills | Turning `auto` on requires Touch ID. |
| Insecure pages | https only (http only for `localhost`, `*.localhost`, `*.test`). |

## What it does not protect against

- **The agent acting as you after login.** Passhand keeps the *password* secret; it doesn't limit what
  an agent does once signed in. With `auto` logins there's no human check at all. Use `auto` for test
  accounts only.
- **Malware running as your user.** It could talk to the same socket or Keychain items (macOS shows a
  prompt for Keychain items created by another binary). Passhand is not a sandbox.
- **The page itself.** After filling, the site's JavaScript can read the field, as with any autofill.
- **A compromised Chrome profile or extension with access to the same pages.**
- **Field labels sent to the local model.** With the optional Ollama fallback, field names and labels
  (never values) go to a model on `127.0.0.1`. Page text is untrusted; the code validates the model's
  picks against the rules above.

## Design notes

- Logins are generic-password items in your login Keychain (`service = "passhand:<origin>"`,
  `account = username`). The fill mode is stored on the item (`fill:touchid` or `fill:auto`).
- The host logs which login was filled where (`~/Library/Application Support/passhand/host.log`),
  never values.
- An unanswered Touch ID prompt is cancelled after 90 seconds, so nothing fills minutes later.
- The `key` in the extension manifest is a public key that pins the extension ID. No private key is in
  this repository.

## Reporting a vulnerability

Please report security issues privately through GitHub: **Security → Report a vulnerability** on this
repository. Don't open a public issue for anything that could put users' accounts at risk.
