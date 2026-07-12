#!/usr/bin/env bash
# Manage isolated ollama server instances — one process per model, each on its own TCP port.
# Each server communicates via IPC (localhost:<port>) so models never share a server process.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$SCRIPT_DIR/models.conf"
PID_DIR="${XDG_RUNTIME_DIR:-/tmp}/ollama-isolated"
LOG_DIR="${PID_DIR}/logs"

# Linux systemd ollama stores pulls under /usr/share/ollama; macOS Homebrew uses ~/.ollama.
if [[ -z "${OLLAMA_MODELS:-}" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
        OLLAMA_MODELS_DIR="${HOME}/.ollama/models"
    else
        OLLAMA_MODELS_DIR="/usr/share/ollama/.ollama/models"
    fi
else
    OLLAMA_MODELS_DIR="$OLLAMA_MODELS"
fi

# Keep warmed models resident until explicitly stopped.
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:--1}"
export OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}"
# Skip probing cuda_v12 / vulkan — pin the CUDA backend on Linux NVIDIA hosts.
if [[ "$(uname -s)" == "Linux" && -z "${OLLAMA_LLM_LIBRARY:-}" ]]; then
    if [[ -d /usr/local/lib/ollama/cuda_v13 ]]; then
        export OLLAMA_LLM_LIBRARY=cuda_v13
    elif [[ -d /usr/local/lib/ollama/cuda_v12 ]]; then
        export OLLAMA_LLM_LIBRARY=cuda_v12
    fi
fi
if [[ "$(uname -s)" == "Linux" ]]; then
    export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
fi

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

    if [[ ! -d "$OLLAMA_MODELS_DIR" ]]; then
        echo "OLLAMA_MODELS dir missing: $OLLAMA_MODELS_DIR" >&2
        return 1
    fi

      # DEBUG timestamps are needed to split warm load into meta vs sched.
      # Pin CUDA library on Linux to avoid multi-backend GPU discovery (~2s).
      (
        export OLLAMA_HOST="127.0.0.1:$port"
        export OLLAMA_MODELS="$OLLAMA_MODELS_DIR"
        export OLLAMA_KEEP_ALIVE="$OLLAMA_KEEP_ALIVE"
        export OLLAMA_MAX_LOADED_MODELS="$OLLAMA_MAX_LOADED_MODELS"
        export OLLAMA_DEBUG="${OLLAMA_DEBUG:-1}"
        [[ -n "${OLLAMA_LLM_LIBRARY:-}" ]] && export OLLAMA_LLM_LIBRARY
        [[ -n "${CUDA_VISIBLE_DEVICES:-}" ]] && export CUDA_VISIBLE_DEVICES
        exec ollama serve
      ) &>"$(_logfile "$model")" &
    local pid=$!
    echo "$pid" > "$(_pidfile "$model")"

    echo -n "Starting $model on port $port (PID $pid, models=$OLLAMA_MODELS_DIR)..."
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
        curl -sf "http://127.0.0.1:$port/api/tags" &>/dev/null && break
        sleep 0.5
    done

    if ! curl -sf "http://127.0.0.1:$port/api/tags" &>/dev/null; then
        echo " FAILED (log: $(_logfile "$model"))"
        rm -f "$(_pidfile "$model")"
        return 1
    fi

    # Fail fast if this isolated server cannot see the requested model.
    if ! curl -sf "http://127.0.0.1:$port/api/tags" | grep -Fq "\"$model\""; then
        echo " ready, but model '$model' not in tags (check OLLAMA_MODELS=$OLLAMA_MODELS_DIR)"
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

cmd_service_start() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
            echo "ollama is already running on :11434"
            return 0
        fi
        if command -v brew >/dev/null 2>&1; then
            brew services start ollama
            echo "ollama started via brew services"
            return 0
        fi
        echo "start the Ollama app, or: ollama serve" >&2
        return 1
    fi
    if systemctl is-active --quiet ollama; then
        echo "ollama is already running"
        systemctl status ollama --no-pager -l | head -5
        return 0
    fi
    sudo systemctl start ollama
    echo "ollama started"
    systemctl status ollama --no-pager -l | head -5
}

cmd_service_stop() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if command -v brew >/dev/null 2>&1; then
            brew services stop ollama
            echo "ollama stopped via brew services"
            return 0
        fi
        echo "quit the Ollama app to stop the service" >&2
        return 1
    fi
    if ! systemctl is-active --quiet ollama; then
        echo "ollama is not running"
        return 0
    fi
    sudo systemctl stop ollama
    echo "ollama stopped"
}

cmd_upgrade() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if command -v brew >/dev/null 2>&1; then
            brew upgrade ollama
            ollama --version
            return 0
        fi
        echo "upgrade via https://ollama.com/download or: brew upgrade ollama" >&2
        return 1
    fi
    # Upgrade the Ollama binary/libs to the latest Linux amd64 release.
    local archive="/tmp/ollama-upgrade/ollama-linux-amd64.tar.zst"
    local install_dir="/usr/local"

    if [[ ! -f "$archive" ]]; then
        echo "Downloading Ollama..."
        mkdir -p "$(dirname "$archive")"
        curl -fL -o "$archive" "https://ollama.com/download/ollama-linux-amd64.tar.zst"
    fi

    echo "Stopping ollama service..."
    sudo systemctl stop ollama || true

    echo "Removing old libraries at ${install_dir}/lib/ollama ..."
    sudo rm -rf "${install_dir}/lib/ollama"

    echo "Extracting ${archive} -> ${install_dir} ..."
    zstd -dc "$archive" | sudo tar -xf - -C "${install_dir}"

    echo "Starting ollama service..."
    sudo systemctl start ollama

    echo "Done:"
    ollama --version
    systemctl is-active ollama
}

cmd_update_models() {
    local models=() model
    while IFS= read -r model; do
        [[ -n "$model" ]] && models+=("$model")
    done < <(ollama list | tail -n +2 | awk '{print $1}')
    if [[ ${#models[@]} -eq 0 ]]; then
        echo "No models installed"
        return 0
    fi
    echo "Updating ${#models[@]} model(s)..."
    for model in "${models[@]}"; do
        echo "--- Pulling $model ---"
        ollama pull "$model"
    done
    echo "All models updated"
    ollama list
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [args]

Isolated model servers:
  start <model>          Start an isolated server for one model
  start-all              Start isolated servers for all models in models.conf
  stop <model>           Stop a model's isolated server
  stop-all               Stop all isolated servers
  list                   Show status of all configured models
  run <model> <prompt>   Send a prompt to an isolated model's server
  logs <model>           Tail the log for a model's server

Main Ollama service / install:
  service-start          Start main Ollama (brew services on macOS, systemd on Linux)
  service-stop           Stop main Ollama
  upgrade                Upgrade Ollama (brew on macOS; Linux amd64 tarball + sudo)
  update-models          ollama pull every locally installed model

Each model runs as its own ollama serve process on a dedicated TCP port.
Connect directly:  OLLAMA_HOST=127.0.0.1:<port> ollama run <model>
Port assignments:  $CONF
Models dir:        $OLLAMA_MODELS_DIR  (override with OLLAMA_MODELS)

Tip: prefer ./gpt <command> for install / panel / bench as well.
EOF
}

case "${1:-}" in
    start)          cmd_start "${2:?Usage: $0 start <model>}" ;;
    start-all)      cmd_start_all ;;
    stop)           cmd_stop "${2:?Usage: $0 stop <model>}" ;;
    stop-all)       cmd_stop_all ;;
    list)           cmd_list ;;
    run)            model="${2:?Usage: $0 run <model> <prompt>}"; shift 2; cmd_run "$model" "$@" ;;
    logs)           cmd_logs "${2:?Usage: $0 logs <model>}" ;;
    service-start)  cmd_service_start ;;
    service-stop)   cmd_service_stop ;;
    upgrade)        cmd_upgrade ;;
    update-models)  cmd_update_models ;;
    *)              usage ;;
esac
