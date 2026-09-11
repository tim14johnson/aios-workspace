#!/bin/bash
# Install oMLX for the AiOS pilot while temporarily selecting the repo's Xcode 27 beta.
# Homebrew checks xcode-select directly on macOS pre-release builds, so DEVELOPER_DIR alone
# cannot satisfy its minimum-Xcode validation. The original selection is restored on exit.
set -euo pipefail

BETA_DEVELOPER_DIR="/Applications/Xcode-beta-b4.app/Contents/Developer"
BREW_BIN="${BREW_BIN:-/opt/homebrew/bin/brew}"

if [ ! -d "$BETA_DEVELOPER_DIR" ]; then
  echo "Expected Xcode 27 beta developer directory is missing: $BETA_DEVELOPER_DIR" >&2
  exit 2
fi

if [ ! -x "$BREW_BIN" ]; then
  echo "Homebrew was not found at $BREW_BIN" >&2
  exit 2
fi

ORIGINAL_DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
RESTORE_NEEDED=0

restore_xcode() {
  status=$?
  trap - EXIT INT TERM
  if [ "$RESTORE_NEEDED" -eq 1 ]; then
    echo
    echo "Restoring the prior Xcode selection: $ORIGINAL_DEVELOPER_DIR"
    if ! sudo /usr/bin/xcode-select --switch "$ORIGINAL_DEVELOPER_DIR"; then
      echo "WARNING: automatic Xcode restoration failed. Run this manually:" >&2
      echo "  sudo /usr/bin/xcode-select --switch \"$ORIGINAL_DEVELOPER_DIR\"" >&2
    fi
  fi
  exit "$status"
}

if [ "$ORIGINAL_DEVELOPER_DIR" != "$BETA_DEVELOPER_DIR" ]; then
  echo "Temporarily selecting Xcode 27 beta for Homebrew:"
  echo "  $BETA_DEVELOPER_DIR"
  echo "The prior selection will be restored automatically after the install."
  trap restore_xcode EXIT INT TERM
  sudo /usr/bin/xcode-select --switch "$BETA_DEVELOPER_DIR"
  RESTORE_NEEDED=1
else
  echo "Xcode 27 beta is already the active developer directory."
fi

"$BREW_BIN" install omlx

if ! command -v omlx >/dev/null 2>&1; then
  echo "Homebrew completed but omlx is not on PATH. Try opening a new Terminal window." >&2
  exit 2
fi

echo
echo "oMLX installed: $(omlx --version 2>&1 | head -1)"
echo "Next: bash tools/start-omlx-pilot.sh"
