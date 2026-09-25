#!/usr/bin/env bash
# Model-library lease for out-of-process jobs (bash/zsh; source it, don't run it).
#
# The Hub's ModelLibrary loads models on demand and offloads them when idle. A script that needs
# the :8080 server must hold a lease so the library doesn't offload the model mid-run:
#
#   source "$REPO_ROOT/tools/lib/brain-lease.sh"
#   brain_lease_acquire "mlx-community/Qwen3.8-27B-4bit" "Overnight queue"   # waits until it answers
#   ...requests to http://127.0.0.1:8080/v1 with "model": "$BRAIN_LEASE_MODEL"...
#   (released automatically on exit; or call brain_lease_release)
#
# The lease file names this shell's pid, so a crashed script's lease is ignored and cleaned up.
# With the Hub's library running (fresh heartbeat), it loads the model (sizing the prompt cache for the hour);
# without it, this helper starts the launchd agent itself with the 2 GB baseline cache and stops
# it again on release when no other lease needs it.

BRAIN_SUPPORT_DIR="${HOME}/Library/Application Support/AiOS"
BRAIN_LEASE_DIR="${BRAIN_SUPPORT_DIR}/model-leases"
BRAIN_AGENT="gui/$(id -u)/com.aios.brain-server"
BRAIN_AGENT_PLIST="${HOME}/Library/LaunchAgents/com.aios.brain-server.plist"
BRAIN_ENDPOINT="http://127.0.0.1:8080/v1"
BRAIN_LEASE_FILE=""
BRAIN_LEASE_MODEL=""

# The Hub's library touches this every ~30 s. Trust it to service a lease only while it's fresh —
# an old Hub build, or a hung one, has a process but no library.
BRAIN_HEARTBEAT="${BRAIN_SUPPORT_DIR}/model-library.heartbeat"
_brain_hub_running() {
    [[ -f "$BRAIN_HEARTBEAT" ]] || return 1
    local age=$(( $(date +%s) - $(stat -f %m "$BRAIN_HEARTBEAT") ))
    (( age < 90 ))
}

_brain_serving() {
    # 0 when the server answers a 1-token request for $1.
    local body
    body=$(printf '{"model":"%s","messages":[{"role":"user","content":"ok"}],"max_tokens":1}' "$1")
    curl -sf -m 300 -H 'Content-Type: application/json' -d "$body" "${BRAIN_ENDPOINT}/chat/completions" > /dev/null 2>&1
}

_brain_running_model() {
    # The --model argument of the running server, if any.
    local pid
    pid=$(launchctl print "$BRAIN_AGENT" 2>/dev/null | awk -F' = ' '/^\tpid = /{print $2}')
    [[ -n "$pid" ]] || return 0
    ps -o args= -p "$pid" 2>/dev/null | sed -n 's/.*--model \(.*\) --port.*/\1/p'
}

_brain_other_live_leases() {
    local f pid
    for f in "$BRAIN_LEASE_DIR"/*.lease; do
        [[ -e "$f" && "$f" != "$BRAIN_LEASE_FILE" ]] || continue
        pid=$(sed -n 's/^pid=//p' "$f")
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}

# brain_lease_acquire <model> [purpose] [timeout-seconds]
brain_lease_acquire() {
    local model="$1" purpose="${2:-external job}" timeout="${3:-900}"
    mkdir -p "$BRAIN_LEASE_DIR"
    BRAIN_LEASE_MODEL="$model"
    BRAIN_LEASE_FILE="${BRAIN_LEASE_DIR}/$(basename "$0" | tr -c 'A-Za-z0-9_.-' '_')-$$.lease"
    printf 'pid=%s\nmodel=%s\npurpose=%s\n' "$$" "$model" "$purpose" > "$BRAIN_LEASE_FILE"
    trap brain_lease_release EXIT

    if ! _brain_hub_running && [[ "$(_brain_running_model)" != "$model" ]]; then
        # No Hub to service the lease: load it ourselves, through launchd like the Hub would.
        printf '%s\n' "$model" > "${BRAIN_SUPPORT_DIR}/brain-model.txt"
        printf '2147483648\n' > "${BRAIN_SUPPORT_DIR}/brain-cache-bytes.txt"
        launchctl print "$BRAIN_AGENT" > /dev/null 2>&1 || launchctl bootstrap "gui/$(id -u)" "$BRAIN_AGENT_PLIST"
        launchctl kickstart -k "$BRAIN_AGENT"
    fi

    local waited=0
    until [[ "$(_brain_running_model)" == "$model" ]] && _brain_serving "$model"; do
        if (( waited >= timeout )); then
            echo "brain-lease: ${model} not serving after ${timeout}s" >&2
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

brain_lease_release() {
    [[ -n "$BRAIN_LEASE_FILE" ]] || return 0
    rm -f "$BRAIN_LEASE_FILE"
    # The Hub offloads on its own idle timer; without it, the last lease out turns the lights off.
    if ! _brain_hub_running && ! _brain_other_live_leases; then
        launchctl kill SIGTERM "$BRAIN_AGENT" > /dev/null 2>&1 || true
    fi
    BRAIN_LEASE_FILE=""
}
