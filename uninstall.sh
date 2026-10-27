#!/bin/bash
# Removes Passhand. Saved logins stay in your Keychain unless you pass --purge.
set -uo pipefail

APP="$HOME/Library/Application Support/passhand"
BIN="$APP/bin/passhand"
HOST="me.shahrestani.passhand"

if [[ -x "$BIN" ]]; then
  "$BIN" uninstall-claude-config
  [[ "${1:-}" == "--purge" ]] && "$BIN" purge
fi

rm -f "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/$HOST.json"
rm -f "$HOME/.local/bin/passhand"
rm -rf "$APP"

echo "Removed. Also remove 'Passhand' from chrome://extensions and restart Claude desktop."
[[ "${1:-}" == "--purge" ]] || echo "Your saved logins are still in the Keychain; run with --purge to delete them too."
