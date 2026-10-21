#!/bin/bash
# One-time setup for automatic updates.
#
# Creates the key Sparkle uses to sign updates (or reuses yours), keeps the
# private half in your login Keychain, writes the public half to
# Sparkle/public_ed_key (commit that file), and exports the private half once
# so you can store it as the SPARKLE_PRIVATE_KEY secret on GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."

SPARKLE_VERSION="2.10.0"
TOOLS="build/sparkle-tools"

if [[ ! -x "$TOOLS/bin/generate_keys" ]]; then
  echo "→ Downloading Sparkle $SPARKLE_VERSION tools…"
  mkdir -p "$TOOLS"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$TOOLS" ./bin
fi

echo "→ Creating or finding your update signing key (macOS may ask for Keychain access)…"
"$TOOLS/bin/generate_keys" >/dev/null
PUBLIC_KEY="$("$TOOLS/bin/generate_keys" -p | tr -d '[:space:]')"

mkdir -p Sparkle
echo "$PUBLIC_KEY" > Sparkle/public_ed_key
echo "✓ Public key saved to Sparkle/public_ed_key"

EXPORT="build/sparkle_private_key.txt"
rm -f "$EXPORT"
"$TOOLS/bin/generate_keys" -x "$EXPORT" >/dev/null
pbcopy < "$EXPORT"
rm -f "$EXPORT"

cat <<'NEXT'
✓ Private key copied to your clipboard (and not saved anywhere else).

Next:
  1. On GitHub: repo › Settings › Secrets and variables › Actions › New repository secret
     Name: SPARKLE_PRIVATE_KEY   Value: paste (⌘V)
  2. Commit the public key:
       git add Sparkle/public_ed_key && git commit -m "Enable automatic updates" && git push
  3. Copy something else so the key isn't left in your clipboard.

Keep the key in your Keychain: every future update must be signed with it.
NEXT
