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
            echo "Stopping llama-server (PID $pid)..."
            kill "$pid" 2>/dev/null
            rm -f "$pid_file"
            echo "Stopped."
            return 0
        fi

        rm -f "$pid_file"
        echo "No running server found. Removed stale PID file."
        return 0
    fi

    # Fallback: stop by process name if no PID file exists
    local pids
    pids=$(pgrep -f "llama-server" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    if [ -n "$pids" ]; then
        echo "Stopping llama-server process(es): $pids"
        pkill -f "llama-server" 2>/dev/null
        echo "Stopped."
    else
        echo "llama-server is not running."
    fi
}
