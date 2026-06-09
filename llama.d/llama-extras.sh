#!/usr/bin/env bash

_llama_logs() {
    local log_file="${LLM_SERVER_LOG_FILE:-$HOME/.llama/llama-server.log}"
    local follow=0
    local lines="200"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--follow)
                follow=1
                ;;
            -n|--lines)
                shift
                lines="${1:-200}"
                ;;
            -h|--help)
                echo "Usage: llama logs [-f|--follow] [-n|--lines N]"
                echo "  -f, --follow      Follow log output"
                echo "  -n, --lines N     Show last N lines (default: 200)"
                return 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Usage: llama logs [-f|--follow] [-n|--lines N]"
                return 1
                ;;
        esac
        shift
    done

    if [ ! -f "$log_file" ]; then
        echo "No log file found at: $log_file"
        echo "Start detached server first: llama serve -d <model>"
        return 1
    fi

    if [ "$follow" = "1" ]; then
        tail -n "$lines" -f "$log_file"
    else
        tail -n "$lines" "$log_file"
    fi
}

_llama_doctor() {
    local model_query="$1"
    local model_path=""
    local log_file="${LLM_SERVER_LOG_FILE:-$HOME/.llama/llama-server.log}"

    if [ -n "$model_query" ]; then
        model_path=$(_llama_find_model "$model_query") || return 1
    fi

    echo ""
    echo "llama doctor"
    echo ""

    if command -v llama-cli >/dev/null 2>&1; then
        echo "[OK] llama-cli found: $(command -v llama-cli)"
    else
        echo "[FAIL] llama-cli not found in PATH"
    fi

    if command -v llama-server >/dev/null 2>&1; then
        echo "[OK] llama-server found: $(command -v llama-server)"
    else
        echo "[FAIL] llama-server not found in PATH"
    fi

    if command -v llama-bench >/dev/null 2>&1; then
        echo "[OK] llama-bench found: $(command -v llama-bench)"
    else
        echo "[FAIL] llama-bench not found in PATH"
    fi

    if command -v hf >/dev/null 2>&1; then
        echo "[OK] hf CLI found: $(command -v hf)"
    else
        echo "[WARN] hf CLI not found (recommended for smoother model downloads)"
    fi

    if [ -d "$LLM_MODELS_DIR" ]; then
        local model_count
        model_count=$(find "$LLM_MODELS_DIR" -maxdepth 1 -name "*.gguf" 2>/dev/null | wc -l | tr -d ' ')
        echo "[OK] models dir: $LLM_MODELS_DIR ($model_count gguf files)"
    else
        echo "[WARN] models dir not found: $LLM_MODELS_DIR"
    fi

    echo ""
    echo "Current env config:"
    echo "  LLM_DEFAULT_CTX=$LLM_DEFAULT_CTX"
    echo "  LLM_DEFAULT_GPU_LAYERS=$LLM_DEFAULT_GPU_LAYERS"
    echo "  LLM_DEFAULT_CACHE_TYPE_K=$LLM_DEFAULT_CACHE_TYPE_K"
    echo "  LLM_DEFAULT_CACHE_TYPE_V=$LLM_DEFAULT_CACHE_TYPE_V"
    echo "  LLM_DEFAULT_THREADS=${LLM_DEFAULT_THREADS:-<auto p-cores>}"
    echo "  LLM_PIPE_N_PREDICT=$LLM_PIPE_N_PREDICT"
    echo "  LLM_NO_THINKING=$LLM_NO_THINKING"

    if _llama_server_running; then
        echo ""
        echo "[OK] Server reachable at http://${LLM_SERVER_HOST}:${LLM_SERVER_PORT}"
    else
        echo ""
        echo "[INFO] Server is not currently running"
    fi

    if [ -f "$log_file" ]; then
        echo "[OK] Log file: $log_file"
    else
        echo "[INFO] Log file not created yet: $log_file"
    fi

    if [ -n "$model_path" ]; then
        echo "[OK] Model resolves: ${model_path##*/}"
        if _llama_binary_supports_mtp llama-cli; then
            if [ "$(_llama_model_tech_for_file "$model_path")" = "MTP" ]; then
                echo "[OK] MTP mode: checkpoint marked as MTP (draft tokens: 2)"
            else
                local draft_model_path=""
                local assistant_dir=""
                if draft_model_path=$(_llama_find_draft_model "$model_path"); then
                    echo "[OK] MTP mode: assistant MTP available (${draft_model_path##*/}, draft tokens: 2)"
                elif assistant_dir=$(_llama_find_local_assistant_dir_for_model "$model_path" 2>/dev/null); then
                    if _llama_binary_supports_gemma_assistant llama-cli; then
                        echo "[OK] MTP mode: assistant safetensors in ${assistant_dir##*/} (llama.cpp auto-detects with --spec-type draft-mtp, draft tokens: $_LLAMA_MTP_DRAFT_N_MAX)"
                    else
                        echo "[WARN] MTP mode: assistant directory found (${assistant_dir##*/})"
                        echo "[INFO] MTP mode: this llama.cpp build lacks gemma4_assistant support"
                    fi
                else
                    echo "[INFO] MTP mode: no MTP path found for this model"
                fi
            fi
        else
            echo "[INFO] MTP mode: llama.cpp binary does not support draft-mtp"
        fi
    fi

    echo ""
}

_llama_pipe() {
    local model_query="$1"; shift
    local instruction="$1"; shift
    local file_path=""
    [[ -n "$1" && -f "$1" ]] && { file_path="$1"; shift; }
    [[ -z "$model_query" || -z "$instruction" ]] && { echo "Usage: llama pipe <model> <instruction> [file]"; return 1; }
    local model_path
    model_path=$(_llama_find_model "$model_query") || return 1
    local stdin_content
    if [[ -n "$file_path" ]]; then
        stdin_content=$(cat "$file_path")
    else
        stdin_content=$(cat)
    fi
    llama-cli --model "$model_path" --n-gpu-layers "$LLM_DEFAULT_GPU_LAYERS" --ctx-size "$LLM_DEFAULT_CTX" \
        --cache-type-k "$(_llama_resolve_cache_type_k)" --cache-type-v "$(_llama_resolve_cache_type_v)" \
        --prompt "${instruction}\n${stdin_content}" --n-predict "$LLM_PIPE_N_PREDICT" --no-display-prompt --log-disable 2>/dev/null
    echo ""
}

_llama_help() {
    echo ""
    echo "Usage: llama <subcommand> [options]"
    echo ""
    echo "Subcommands:"
    echo "  run [--no-thinking] <model> [args]   Run interactively (auto-MTP for supported models)"
    echo "  serve [-d] [--no-thinking] <model> [args]  Start OpenAI-compatible API server (auto-MTP for supported models)"
    echo "  list [-a]              List local models (-a shows mmproj files)"
    echo "  pull <repo-or-url>     Pull model files (GGUF chooser; MLX repos auto-download fully)"
    echo "  rm|remove <model...>   Remove one or more models and their mmproj files"
    echo "  stop                   Stop running server"
    echo "  ps                     Show server status"
    echo "  logs [-f] [-n N]       Show/follow detached server logs"
    echo "  doctor [model]         Check binaries, models dir, and server health"
    echo "  config <key> ...       Set runtime env toggles without manual export"
    echo "  bench <model>          Run benchmark"
    echo "  speed <model> [--tokens N] [--runs N]   Measure generation speed via llama-cli"
    echo "  pipe <model> <instr> [file]  Pipe stdin or file into model with instruction"
    echo "  opencode|pi <model>    Register model in OpenCode + Pi configs"
    echo "  help                   Show this help"
    echo ""
    echo "Environment variables:"
    echo "  LLM_MODELS_DIR         Model storage directory (default: \$HOME/.llama/llama-models)"
    echo "  LLM_DEFAULT_CTX        Context size (default: 32768)"
    echo "  LLM_DEFAULT_GPU_LAYERS GPU layers (default: 99)"
    echo "  LLM_DEFAULT_CACHE_TYPE_K KV cache K type (default: f16)"
    echo "  LLM_DEFAULT_CACHE_TYPE_V KV cache V type (default: f16)"
    echo "  LLM_DEFAULT_THREADS    CPU threads (default: auto p-cores on Apple)"
    echo "  LLM_PIPE_N_PREDICT     Default output tokens for 'llama pipe' (4096)"
    echo "  LLM_NO_THINKING        Disable Qwen thinking by default: 0|1 (default: 0)"
    echo "  LLM_RUNTIME_CONFIG_FILE Default file for 'llama config save/load'"
    echo "  LLM_SERVER_HOST        Server host (default: 127.0.0.1)"
    echo "  LLM_SERVER_PORT        Server port (default: 11434)"
    echo "  LLM_SERVER_LOG_FILE    Log file for detached server"
    echo "  LLM_SERVER_MIN_SPINNER_STEPS Minimum spinner frames before ready (default: 3)"
    echo ""
    echo "Helpers:"
    echo "  llama config threads auto      # use Apple performance-core thread count"
    echo "  llama config cache q8_0        # common safe KV speed boost"
    echo "  llama config save              # persist current toggles"
    echo "  llama config load              # restore saved toggles"
    echo ""
    echo "🦙 \033[2mllama.cpp\033[0m"
}

llama-speed() {
    _llama_speed "$@"
}

llama-pipe() {
    _llama_pipe "$@"
}
