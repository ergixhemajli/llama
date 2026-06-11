#!/usr/bin/env bash
# llama-server.sh — Serve models via llama-server

_llama_pick_serve_model_from_list() {
    if ! command -v fzf >/dev/null 2>&1; then
        echo "Error: no model provided and fzf is not installed for interactive selection." >&2
        echo "Install fzf or run: llama list" >&2
        echo "Then pass a model explicitly: llama serve <model>" >&2
        return 1
    fi

    [ -t 0 ] || {
        echo "Error: interactive model selection requires a TTY. Pass a model explicitly." >&2
        return 1
    }

    local selected
    selected=$(_llama_list \
        | awk 'NF > 0' \
        | grep -v '^NAME[[:space:]]' \
        | grep -v '^-[-[:space:]]*$' \
        | grep -v 'mmproj' \
        | grep -v -- '-MTP-' \
        | grep -v 'assistant' \
        | fzf --ansi --height=70% --layout=reverse \
            --prompt='serve model > ' \
            --header='Select model from llama list (PATH used internally)') || return 1

    printf '%s\n' "$selected" | sed -E 's/.* (\/[^ ]+\.gguf)$/\1/'
}

_llama_serve() {
    local detached=0
    local mtp=0
    local mtp_model_query=""
    local mtp_draft_n_max="${_LLAMA_MTP_DRAFT_N_MAX:-2}"
    local model_query=""
    local extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--detached)
                detached=1
                shift
                ;;
            --mtp)
                mtp=1
                shift
                ;;
            --mtp-model)
                mtp=1
                shift
                if [ -z "${1:-}" ]; then
                    echo "Error: --mtp-model requires a model path or query"
                    return 1
                fi
                mtp_model_query="$1"
                shift
                ;;
            --mtp-draft-n-max)
                mtp=1
                shift
                if [[ ! "${1:-}" =~ ^[0-9]+$ ]]; then
                    echo "Error: --mtp-draft-n-max requires an integer"
                    return 1
                fi
                mtp_draft_n_max="$1"
                shift
                ;;
            -h|--help)
                echo "Usage: llama serve [-d|--detached] [--mtp] [--mtp-model <draft_model>] [--mtp-draft-n-max <n>] [model_query] [additional llama-server args...]"
                echo "If model_query is omitted, an interactive picker is shown (fzf, based on llama list)."
                return 0
                ;;
            *)
                if [ -z "$model_query" ] && [[ "$1" != -* ]]; then
                    model_query="$1"
                else
                    extra_args+=("$1")
                fi
                shift
                ;;
        esac
    done

    local model_path=""
    if [ -z "$model_query" ]; then
        model_path=$(_llama_pick_serve_model_from_list) || return 1
        model_query="${model_path##*/}"
        model_query="${model_query%.gguf}"
        echo "Selected model: $model_query"
    else
        # Find model
        model_path=$(_llama_find_model "$model_query")
        if [ -z "$model_path" ]; then
            echo "Model not found: $model_query"
            return 1
        fi
    fi

    local pidfile="$LLM_MODELS_DIR/.llama-server.pid"

    # Check if already running
    if [ -f "$pidfile" ]; then
        local old_pid
        old_pid=$(cat "$pidfile")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "llama-server already running (PID: $old_pid)"
            echo "Use 'llama stop' to stop it first, or use 'llama ps' to check"
            return 1
        else
            echo "Stale PID file found, removing"
            rm -f "$pidfile"
        fi
    fi

    # Start server
    local cmd="llama-server"
    local log_file="${LLM_SERVER_LOG_FILE:-$HOME/.llama/llama-server.log}"
    local cmd_args=(
        --model "$model_path"
        --ctx-size "$LLM_DEFAULT_CTX"
        --n-gpu-layers "$LLM_DEFAULT_GPU_LAYERS"
        --cache-type-k "$LLM_DEFAULT_CACHE_TYPE_K"
        --cache-type-v "$LLM_DEFAULT_CACHE_TYPE_V"
        --host "$LLM_SERVER_HOST"
        --port "$LLM_SERVER_PORT"
        --mlock
    )

    if [ "$mtp" -eq 1 ]; then
        if ! _llama_binary_supports_mtp "$cmd"; then
            echo "Error: this llama-server build does not support MTP (missing draft-mtp)."
            return 1
        fi

        local draft_model_path=""
        if [ -n "$mtp_model_query" ]; then
            draft_model_path=$(_llama_find_model "$mtp_model_query") || return 1
            cmd_args+=(--spec-type draft-mtp --spec-draft-model "$draft_model_path" --spec-draft-n-max "$mtp_draft_n_max")
            echo "MTP: enabled with explicit draft model (${draft_model_path##*/}, n-max=$mtp_draft_n_max)"
        elif [ "$(_llama_model_tech_for_file "$model_path")" = "MTP" ]; then
            cmd_args+=(--spec-type draft-mtp --spec-draft-n-max "$mtp_draft_n_max")
            echo "MTP: enabled (embedded/marked model, n-max=$mtp_draft_n_max)"
        elif draft_model_path=$(_llama_find_draft_model "$model_path" 2>/dev/null); then
            cmd_args+=(--spec-type draft-mtp --spec-draft-model "$draft_model_path" --spec-draft-n-max "$mtp_draft_n_max")
            echo "MTP: enabled with paired draft model (${draft_model_path##*/}, n-max=$mtp_draft_n_max)"
        elif draft_model_path=$(_llama_resolve_assistant_gguf_for_model "$model_path" 2>/dev/null); then
            cmd_args+=(--spec-type draft-mtp --spec-draft-model "$draft_model_path" --spec-draft-n-max "$mtp_draft_n_max")
            echo "MTP: enabled with assistant draft model (${draft_model_path##*/}, n-max=$mtp_draft_n_max)"
        else
            echo "Error: --mtp requested, but no compatible draft model path was found for ${model_path##*/}."
            echo "Hint: pass --mtp-model <draft-model> explicitly or use a model marked as MTP."
            return 1
        fi
    fi

    cmd_args+=("${extra_args[@]}")

    if [ "$detached" -eq 1 ]; then
        "$cmd" "${cmd_args[@]}" >>"$log_file" 2>&1 &

        local pid=$!
        sleep 0.2
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "Failed to start llama-server (exited immediately)."
            echo "Check logs: $log_file"
            return 1
        fi

        echo "$pid" > "$pidfile"
        echo "llama-server started (PID: $pid)"
        echo "Model: $model_path"
        echo "Host: http://localhost:$LLM_SERVER_PORT"
        echo "Logs: $log_file"
        return 0
    fi

    echo "Starting llama-server in foreground (Ctrl+C to stop)…"
    "$cmd" "${cmd_args[@]}"
}

# Stop llama-server
_llama_stop() {
    local pidfile="$LLM_MODELS_DIR/.llama-server.pid"
    if [ -f "$pidfile" ]; then
        local pid
        pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            rm -f "$pidfile"
            echo "llama-server stopped (PID: $pid)"
        else
            echo "Process $pid not running, removing stale PID file"
            rm -f "$pidfile"
        fi
    else
        echo "llama-server not running"
    fi
}

# List running llama-server instances
_llama_ps() {
    local show_args=0
    for arg in "$@"; do
        if [ "$arg" = "--args" ]; then
            show_args=1
        fi
    done

    local proc
    proc=$(ps aux 2>/dev/null | grep llama-server | grep -v grep)

    if [ -z "$proc" ]; then
        echo "No llama-server processes running"
        return
    fi

    # Print header
    printf "%-8s %-40s %-8s %-8s %-6s %-6s\n" "PID" "MODEL" "PORT" "CTX" "CPU%" "MEM%"
    printf "%-8s %-40s %-8s %-8s %-6s %-6s\n" "--------" "----------------------------------------" "--------" "--------" "------" "------"

    # Parse each process line
    while IFS= read -r line; do
        local pid user cpu mem vsz rss tty stat start time cmd
        read -r user pid cpu mem vsz rss tty stat start time cmd <<< "$line"

        # Extract model name from --model flag
        local model_name="unknown"
        if echo "$cmd" | grep -q -- '--model'; then
            model_name=$(echo "$cmd" | grep -o -- '--model [^ ]*' | awk '{print $2}')
            model_name=$(basename "$model_name" .gguf)
            model_name=$(echo "$model_name" | sed -E 's/[-_]((UD|UDT)-)?(IQ[0-9]+_[A-Z0-9]+|Q[0-9]+_[A-Z0-9]+|Q[0-9]+_[A-Z0-9]+_[A-Z0-9]+|Q[0-9]+_[0-9]+|BF16|F16)$//')
            model_name=$(echo "$model_name" | sed -E 's/.*-GGUF-//')
            model_name=$(echo "$model_name" | sed -E 's/[-_](MTP|assistant)$//I')
        fi

        # Extract context size from --ctx-size flag
        local ctx_size="?"
        if echo "$cmd" | grep -q -- '--ctx-size'; then
            ctx_size=$(echo "$cmd" | grep -o -- '--ctx-size [^ ]*' | awk '{print $2}')
        fi

        # Extract port from --port flag
        local port="?"
        if echo "$cmd" | grep -q -- '--port'; then
            port=$(echo "$cmd" | grep -o -- '--port [^ ]*' | awk '{print $2}')
        fi

        printf "%-8s %-40s %-8s %-8s %-6s %-6s\n" "$pid" "$model_name" "$port" "$ctx_size" "$cpu" "$mem"

        # Show args if --args flag was passed
        if [ "$show_args" -eq 1 ]; then
            echo "  PID $pid: $cmd"
        fi
    done <<< "$proc"
}
