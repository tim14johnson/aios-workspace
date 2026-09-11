#!/bin/bash
# Refreshes the Plaud MCP OAuth token on disk (~/.plaud/tokens-mcp.json).
#
# Plaud access tokens expire every ~24h. The Plaud CLI refreshes them (using the stored
# refresh token) when it starts and services a request — but the sandboxed AiOSHub app
# cannot spawn node to do this itself. This script runs the CLI briefly to force a refresh,
# and is driven by a launchd LaunchAgent every ~12h so the token is always fresh when the
# Hub's HTTP client reads it.
#
# Reversible: `launchctl bootout gui/$UID ~/Library/LaunchAgents/com.mazzarothpictures.aios.plaud-refresh.plist`

# launchd runs with a minimal PATH; npx re-execs `env node`, so node's dir must be on PATH.
export PATH="/usr/local/bin:$PATH"

NODE="/usr/local/bin/node"
NPX="/usr/local/lib/node_modules/npm/bin/npx-cli.js"
LOG="$HOME/Library/Logs/aios-plaud-refresh.log"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] plaud-refresh starting" >> "$LOG"

# Guard: if node/npx aren't present, log and exit cleanly (don't let launchd retry-storm).
if [ ! -x "$NODE" ] || [ ! -f "$NPX" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] node/npx not found — skipping" >> "$LOG"
  exit 0
fi

# Feed the stdio MCP server an initialize + one tool call, which triggers the token refresh,
# then let it idle briefly and kill it.
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"aios-refresh","version":"1.0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_current_user","arguments":{}}}'
  sleep 8
} | "$NODE" "$NPX" --yes @plaud-ai/mcp@latest >/dev/null 2>>"$LOG" &

SERVER_PID=$!
sleep 12
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null

echo "[$(date '+%Y-%m-%d %H:%M:%S')] plaud-refresh done" >> "$LOG"
exit 0
