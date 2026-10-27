#!/bin/bash
# Installs Passhand: builds the helper, registers it with Chrome and Claude desktop.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Library/Application Support/passhand"
BIN="$APP/bin/passhand"
EXT_DIR="$APP/extension"
EXT_ID="alpckagkehodlliniailejachglpeinb"
HOST="me.shahrestani.passhand"
NMH_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"

[[ "$(uname)" == "Darwin" ]] || { echo "Passhand runs on macOS only."; exit 1; }
command -v swift >/dev/null || { echo "Swift not found. Install Xcode or run: xcode-select --install"; exit 1; }

echo "→ Building the helper (release)…"
swift build -c release --package-path "$HERE/helper"

echo "→ Installing to $APP"
mkdir -p "$APP/bin"
chmod 700 "$APP"
install -m 755 "$HERE/helper/.build/release/passhand" "$BIN"

# A real signing identity keeps Keychain access stable across rebuilds; with the default ad-hoc
# signature macOS asks "Allow access?" after every rebuild, which would block unattended fills.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
if [[ -n "$IDENTITY" ]]; then
  echo "→ Signing with \"$IDENTITY\""
  codesign --force --sign "$IDENTITY" --identifier me.shahrestani.passhand "$BIN"
else
  echo "→ No signing identity found; keeping the ad-hoc signature (macOS may ask once after each rebuild)"
fi
rm -rf "$EXT_DIR"
cp -R "$HERE/extension" "$EXT_DIR"

# Stop a helper from a previous install; Chrome restarts the new one within a minute (or on extension reload).
pkill -f 'passhand chrome-extension://' 2>/dev/null || true

echo "→ Registering the native messaging host with Chrome"
mkdir -p "$NMH_DIR"
cat > "$NMH_DIR/$HOST.json" <<EOF
{
  "name": "$HOST",
  "description": "Passhand helper",
  "path": "$BIN",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXT_ID/"]
}
EOF

echo "→ Registering the fill_login tool with Claude desktop"
"$BIN" install-claude-config "$BIN"

# Put the command on your PATH.
mkdir -p "$HOME/.local/bin"
ln -sf "$BIN" "$HOME/.local/bin/passhand"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo
     echo "Note: add ~/.local/bin to your PATH to use the 'passhand' command:"
     echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;;
esac

printf '%s' "$EXT_DIR" | pbcopy

cat <<EOF

✓ Helper installed. Three steps left:

1. Load the extension in Chrome
   • Open chrome://extensions and switch on "Developer mode" (top right)
   • Click "Load unpacked", press ⇧⌘G, paste (the folder path is on your clipboard), press Enter, then Select
   • You should see "Passhand" with ID $EXT_ID

2. Quit and reopen Claude desktop so it picks up the fill_login tool.

3. Save your first login and check everything:
     passhand add github.com you@example.com
     passhand doctor

Optional: for unusual login forms, install Ollama and run:  ollama pull qwen2.5:3b
EOF
