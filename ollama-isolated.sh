#!/usr/bin/env bash
# Manage isolated ollama server instances — one process per model, each on its own TCP port.
# Each server communicates via IPC (localhost:<port>) so models never share a server process.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$SCRIPT_DIR/models.conf"
PID_DIR="${XDG_RUNTIME_DIR:-/tmp}/ollama-isolated"
LOG_DIR="${PID_DIR}/logs"

_load_conf() {
    [[ -f "$CONF" ]] || { echo "Config not found: $CONF"; exit 1; }
}

_port_for() {
    local model="$1"
    grep -m1 "^${model}=" "$CONF" | cut -d= -f2
}

_model_for_port() {
    local port="$1"
    grep -m1 "=${port}$" "$CONF" | cut -d= -f1
}

_pidfile() { echo "$PID_DIR/${1//[:\/ ]/_}.pid"; }
_logfile() { echo "$LOG_DIR/${1//[:\/ ]/_}.log"; }

_is_running() {
    local pid_file; pid_file="$(_pidfile "$1")"
    [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}

cmd_start() {
    local model="$1"
    _load_conf
    local port; port="$(_port_for "$model")"
    [[ -z "$port" ]] && { echo "Unknown model: $model (not in $CONF)"; exit 1; }

    if _is_running "$model"; then
        echo "$model already running on port $port (PID $(cat "$(_pidfile "$model")"))"
        return 0
    fi

    mkdir -p "$PID_DIR" "$LOG_DIR"

    OLLAMA_HOST="127.0.0.1:$port" ollama serve &>"$(_logfile "$model")" &
    local pid=$!
    echo "$pid" > "$(_pidfile "$model")"

    echo -n "Starting $model on port $port (PID $pid)..."
    for i in {1..30}; do
        curl -sf "http://127.0.0.1:$port/api/tags" &>/dev/null && break
        sleep 0.5
    done

    if ! curl -sf "http://127.0.0.1:$port/api/tags" &>/dev/null; then
        echo " FAILED (log: $(_logfile "$model"))"
        rm -f "$(_pidfile "$model")"
        return 1
    fi
    echo " ready"
}

cmd_stop() {
    local model="$1"
    local pid_file; pid_file="$(_pidfile "$model")"
    if ! _is_running "$model"; then
        echo "$model is not running"
        [[ -f "$pid_file" ]] && rm -f "$pid_file"
        return 0
    fi
    local pid; pid=$(cat "$pid_file")
    kill "$pid" && echo "$model stopped (PID $pid)" || echo "Failed to stop $model"
    rm -f "$pid_file"
}

cmd_start_all() {
    _load_conf
    local pids=()
    while IFS='=' read -r model port; do
        [[ "$model" =~ ^# ]] || [[ -z "$model" ]] && continue
        cmd_start "$model" &
        pids+=($!)
    done < "$CONF"
    for pid in "${pids[@]}"; do wait "$pid" || true; done
    echo "All models started"
}

cmd_stop_all() {
    find "$PID_DIR" -maxdepth 1 -name '*.pid' | while read -r pid_file; do
        local pid; pid=$(cat "$pid_file")
        local name; name=$(basename "$pid_file" .pid)
        if kill "$pid" 2>/dev/null; then
            echo "Stopped $name (PID $pid)"
        fi
        rm -f "$pid_file"
    done
}

cmd_list() {
    _load_conf
    printf "%-30s %-8s %-10s %s\n" "MODEL" "PORT" "STATUS" "PID"
    printf "%-30s %-8s %-10s %s\n" "-----" "----" "------" "---"
    while IFS='=' read -r model port; do
        [[ "$model" =~ ^# ]] || [[ -z "$model" ]] && continue
        local status pid="-"
        if _is_running "$model"; then
            pid=$(cat "$(_pidfile "$model")")
            status="running"
        else
            status="stopped"
        fi
        printf "%-30s %-8s %-10s %s\n" "$model" "$port" "$status" "$pid"
    done < "$CONF"
}

cmd_run() {
    local model="$1"; shift
    _load_conf
    local port; port="$(_port_for "$model")"
    [[ -z "$port" ]] && { echo "Unknown model: $model"; exit 1; }
    if ! _is_running "$model"; then
        echo "Error: $model is not running. Start it with: $0 start $model"
        exit 1
    fi
    OLLAMA_HOST="127.0.0.1:$port" ollama run "$model" "$*"
}

cmd_logs() {
    local model="$1"
    local log; log="$(_logfile "$model")"
    [[ -f "$log" ]] || { echo "No log for $model"; exit 1; }
    tail -f "$log"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  start <model>          Start an isolated server for one model
  start-all              Start isolated servers for all models in models.conf
  stop <model>           Stop a model's isolated server
  stop-all               Stop all isolated servers
  list                   Show status of all configured models
  run <model> <prompt>   Send a prompt to an isolated model's server
  logs <model>           Tail the log for a model's server

Each model runs as its own ollama serve process on a dedicated TCP port.
Connect directly:  OLLAMA_HOST=127.0.0.1:<port> ollama run <model>
Port assignments:  $CONF
EOF
}

case "${1:-}" in
    start)     cmd_start "${2:?Usage: $0 start <model>}" ;;
    start-all) cmd_start_all ;;
    stop)      cmd_stop "${2:?Usage: $0 stop <model>}" ;;
    stop-all)  cmd_stop_all ;;
    list)      cmd_list ;;
    run)       model="${2:?Usage: $0 run <model> <prompt>}"; shift 2; cmd_run "$model" "$@" ;;
    logs)      cmd_logs "${2:?Usage: $0 logs <model>}" ;;
    *)         usage ;;
esac
