#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ -f "./sources.json" ]; then
  SOURCES_FILE="$(pwd)/sources.json"
elif [ -f "${SCRIPT_DIR}/sources.json" ]; then
  SOURCES_FILE="${SCRIPT_DIR}/sources.json"
elif GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) && [ -f "$GIT_ROOT/sources.json" ]; then
  SOURCES_FILE="$GIT_ROOT/sources.json"
else
  echo "Error: Could not locate sources.json (checked ./sources.json, ${SCRIPT_DIR}/sources.json, and git root)" >&2
  exit 1
fi

echo "==> Reading current versions from sources.json..."
CURRENT_CLI_VERSION=$(jq -r '.cli.version // empty' "$SOURCES_FILE")
CURRENT_CLI_BUILD=$(jq -r '.cli.buildId // empty' "$SOURCES_FILE")
CURRENT_CLI_HASH=$(jq -r '.cli.hash // empty' "$SOURCES_FILE")

CURRENT_HUB_VERSION=$(jq -r '.hub.version // empty' "$SOURCES_FILE")
CURRENT_HUB_BUILD=$(jq -r '.hub.buildId // empty' "$SOURCES_FILE")
CURRENT_HUB_HASH=$(jq -r '.hub.hash // empty' "$SOURCES_FILE")

echo "    Current CLI: ${CURRENT_CLI_VERSION:-none} (${CURRENT_CLI_BUILD:-none})"
echo "    Current Hub: ${CURRENT_HUB_VERSION:-none} (${CURRENT_HUB_BUILD:-none})"

echo "==> Checking upstream release manifests..."
CLI_MANIFEST=$(curl -sSfL "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json")
LATEST_CLI_VERSION=$(echo "$CLI_MANIFEST" | jq -r .version)
LATEST_CLI_URL=$(echo "$CLI_MANIFEST" | jq -r .url)
LATEST_CLI_BUILD=$(echo "$LATEST_CLI_URL" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | cut -d- -f2)

HUB_MANIFEST=$(curl -sSfL "https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/latest-x64-linux.yml")
LATEST_HUB_VERSION=$(echo "$HUB_MANIFEST" | grep '^version:' | awk '{print $2}')
LATEST_HUB_URL=$(echo "$HUB_MANIFEST" | grep -m1 'url:' | awk '{print $NF}')
LATEST_HUB_BUILD=$(echo "$LATEST_HUB_URL" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | cut -d- -f2)
LATEST_HUB_TAR_URL="https://storage.googleapis.com/antigravity-public/antigravity-hub/${LATEST_HUB_VERSION}-${LATEST_HUB_BUILD}/linux-x64/Antigravity.tar.gz"

echo "    Upstream CLI: ${LATEST_CLI_VERSION} (${LATEST_CLI_BUILD})"
echo "    Upstream Hub: ${LATEST_HUB_VERSION} (${LATEST_HUB_BUILD})"

CLI_CHANGED=false
HUB_CHANGED=false

if [ "$CURRENT_CLI_VERSION" != "$LATEST_CLI_VERSION" ] || [ "$CURRENT_CLI_BUILD" != "$LATEST_CLI_BUILD" ] || [ -z "$CURRENT_CLI_HASH" ]; then
  CLI_CHANGED=true
fi

if [ "$CURRENT_HUB_VERSION" != "$LATEST_HUB_VERSION" ] || [ "$CURRENT_HUB_BUILD" != "$LATEST_HUB_BUILD" ] || [ -z "$CURRENT_HUB_HASH" ]; then
  HUB_CHANGED=true
fi

if [ "$CLI_CHANGED" = false ] && [ "$HUB_CHANGED" = false ]; then
  echo "==> Everything is already up to date. No downloads needed."
  exit 0
fi

# Fetch CLI hash if changed
if [ "$CLI_CHANGED" = true ]; then
  echo "==> Fetching new hash for Antigravity CLI (${CURRENT_CLI_VERSION} -> ${LATEST_CLI_VERSION})..."
  CLI_HASH=$(nix store prefetch-file "$LATEST_CLI_URL" --json | jq -r .hash)
  echo "    New CLI hash: $CLI_HASH"
else
  echo "==> Antigravity CLI unchanged (${CURRENT_CLI_VERSION}). Reusing existing hash."
  CLI_HASH="$CURRENT_CLI_HASH"
fi

# Fetch Hub hash if changed
if [ "$HUB_CHANGED" = true ]; then
  echo "==> Fetching new hash for Antigravity Hub (${CURRENT_HUB_VERSION} -> ${LATEST_HUB_VERSION})..."
  HUB_HASH=$(nix store prefetch-file "$LATEST_HUB_TAR_URL" --json | jq -r .hash)
  echo "    New Hub hash: $HUB_HASH"
else
  echo "==> Antigravity Hub unchanged (${CURRENT_HUB_VERSION}). Reusing existing hash."
  HUB_HASH="$CURRENT_HUB_HASH"
fi

echo "==> Writing updated ${SOURCES_FILE}..."
TMP_FILE=$(mktemp)
jq -n \
  --arg cv "$LATEST_CLI_VERSION" --arg cb "$LATEST_CLI_BUILD" --arg ch "$CLI_HASH" \
  --arg hv "$LATEST_HUB_VERSION" --arg hb "$LATEST_HUB_BUILD" --arg hh "$HUB_HASH" \
  '{
    cli: { version: $cv, buildId: $cb, hash: $ch },
    hub: { version: $hv, buildId: $hb, hash: $hh }
  }' > "$TMP_FILE"

mv "$TMP_FILE" "$SOURCES_FILE"
echo "==> Successfully updated sources.json:"
cat "$SOURCES_FILE"
