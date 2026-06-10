#!/usr/bin/env bash
# llama-stop.sh — Stop running llama-server processes

_llama_stop() {
    local pid_file_models="${LLM_MODELS_DIR:-$HOME/.llama/llama-models}/.llama-server.pid"
    local pid_file_legacy="$HOME/.llama/llama-server.pid"
    local pid_file="$pid_file_models"

    if [ ! -f "$pid_file" ] && [ -f "$pid_file_legacy" ]; then
        pid_file="$pid_file_legacy"
    fi

    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "Stopping llama-server (PID: $pid)..."
            kill "$pid" 2>/dev/null
            rm -f "$pid_file"
            echo "llama-server stopped."
        else
            echo "No running llama-server found (stale PID file removed)."
            rm -f "$pid_file"
        fi
    else
        # Fallback: kill by name
        if pgrep -f "llama-server" >/dev/null 2>&1; then
            echo "Stopping llama-server processes..."
            pkill -f "llama-server" 2>/dev/null
            echo "Done."
        else
            echo "No llama-server processes found."
        fi
    fi
}
