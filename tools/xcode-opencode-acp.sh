#!/bin/bash
# Xcode ACP bootstrap for AiOS.
# ACP must keep stdout exclusively for newline-delimited JSON-RPC messages.
# Diagnostics are therefore written only to a local stderr log.
set -u

REPO="/Volumes/AiOS Repository/code"
LOG_DIR="$HOME/Library/Logs/AiOS"
LOG_FILE="$LOG_DIR/opencode-acp.log"

mkdir -p "$LOG_DIR" 2>/dev/null || true
{
  printf '\n=== OpenCode ACP launch %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf 'cwd: %s\n' "$REPO"
  printf 'opencode: %s\n' "$(/opt/homebrew/bin/opencode --version 2>&1 || true)"
} >>"$LOG_FILE" 2>/dev/null || true

cd "$REPO" || {
  printf 'ERROR: Cannot enter repository: %s\n' "$REPO" >>"$LOG_FILE" 2>/dev/null || true
  exit 1
}

# Keep this invocation intentionally identical to OpenCode's ACP documentation.
# Do not print from this wrapper: stdout is the ACP JSON-RPC transport.
exec /opt/homebrew/bin/opencode acp 2>>"$LOG_FILE"
