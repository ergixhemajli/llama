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
    local model_query=""
    local model_path=""
    local download_mmproj=0
    local log_file="${LLM_SERVER_LOG_FILE:-$HOME/.llama/llama-server.log}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --download-mmproj)
                download_mmproj=1
                shift
                ;;
            -h|--help)
                echo "Usage: llama doctor [model] [--download-mmproj]"
                echo "  --download-mmproj   Download missing mmproj-F16.gguf files when repo metadata is available"
                return 0
                ;;
            *)
                if [ -z "$model_query" ]; then
                    model_query="$1"
                    shift
                else
                    echo "Unknown argument: $1"
                    echo "Usage: llama doctor [model] [--download-mmproj]"
                    return 1
                fi
                ;;
        esac
    done

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
                echo "[OK] MTP mode: checkpoint marked as MTP (draft tokens: ${_LLAMA_MTP_DRAFT_N_MAX:-2})"
            else
                local draft_model_path=""
                local assistant_dir=""
                if draft_model_path=$(_llama_find_draft_model "$model_path"); then
                    echo "[OK] MTP mode: assistant MTP available (${draft_model_path##*/}, draft tokens: ${_LLAMA_MTP_DRAFT_N_MAX:-2})"
                elif assistant_dir=$(_llama_find_local_assistant_dir_for_model "$model_path" 2>/dev/null); then
                    if _llama_binary_supports_gemma_assistant llama-cli; then
                        echo "[OK] MTP mode: assistant safetensors in ${assistant_dir##*/} (llama.cpp auto-detects with --spec-type draft-mtp, draft tokens: ${_LLAMA_MTP_DRAFT_N_MAX:-2})"
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

    local targets=()
    if [ -n "$model_path" ]; then
        targets+=("$model_path")
    elif [ -d "$LLM_MODELS_DIR" ]; then
        while IFS= read -r -d '' f; do
            local bname="${f##*/}"
            [[ "$bname" == mmproj* ]] && continue
            targets+=("$f")
        done < <(find "$LLM_MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null | sort -z)
    fi

    local mmproj_missing=0
    local mmproj_downloaded=0
    local mmproj_failed=0

    if [ ${#targets[@]} -gt 0 ]; then
        echo ""
        echo "mmproj check:"
        local target filename mmproj_path repo model_base stripped_base mmproj_out mmproj_remote http_status
        mmproj_remote="mmproj-F16.gguf"

        for target in "${targets[@]}"; do
            filename="${target##*/}"
            if mmproj_path=$(_llama_find_mmproj "$target" 2>/dev/null); then
                echo "[OK] mmproj: ${filename} -> ${mmproj_path##*/}"
                continue
            fi

            mmproj_missing=$((mmproj_missing + 1))
            echo "[WARN] mmproj missing: ${filename} (needed for vision inputs only)"

            if [ "$download_mmproj" -eq 0 ]; then
                continue
            fi

            repo=$(_llama_model_meta_get_field "$filename" repo)
            if [ -z "$repo" ]; then
                echo "  [INFO] no repo metadata for ${filename}; cannot auto-download mmproj"
                mmproj_failed=$((mmproj_failed + 1))
                continue
            fi

            http_status=$(curl -sf -o /dev/null -w "%{http_code}" -L --max-time 5 "https://huggingface.co/${repo}/resolve/main/${mmproj_remote}" 2>/dev/null)
            if [ "$http_status" != "200" ]; then
                echo "  [INFO] mmproj-F16.gguf not available in ${repo}"
                mmproj_failed=$((mmproj_failed + 1))
                continue
            fi

            model_base="${filename%.gguf}"
            stripped_base=$(echo "$model_base" | sed -E 's/[-_]((UD|UDT)-)?Q[0-9]+_[A-Z0-9]+(_[A-Z0-9]+)*$//')
            mmproj_out="$LLM_MODELS_DIR/mmproj-F16-${stripped_base}.gguf"

            echo "  ▶ downloading mmproj for ${filename} ..."
            if command -v hf >/dev/null 2>&1; then
                hf download "$repo" --include "$mmproj_remote" --local-dir "$LLM_MODELS_DIR" >/dev/null 2>&1
                [ -f "$LLM_MODELS_DIR/$mmproj_remote" ] && mv -f "$LLM_MODELS_DIR/$mmproj_remote" "$mmproj_out"
            else
                curl -L --progress-bar -o "$mmproj_out" "https://huggingface.co/${repo}/resolve/main/${mmproj_remote}" >/dev/null 2>&1
            fi

            if [ -f "$mmproj_out" ]; then
                echo "  [OK] downloaded ${mmproj_out##*/}"
                mmproj_downloaded=$((mmproj_downloaded + 1))
            else
                echo "  [WARN] download failed for ${filename}"
                mmproj_failed=$((mmproj_failed + 1))
            fi
        done

        if [ "$download_mmproj" -eq 0 ] && [ "$mmproj_missing" -gt 0 ]; then
            echo "[INFO] Run again with: llama doctor ${model_query:-} --download-mmproj"
        elif [ "$download_mmproj" -eq 1 ]; then
            echo "[INFO] mmproj download summary: downloaded=$mmproj_downloaded failed=$mmproj_failed missing_before=$mmproj_missing"
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
    echo "  run [--no-thinking] <model> [args]   Run interactively"
    echo "  serve [-d] [--mtp] [--mtp-model <draft>] [--mtp-draft-n-max N] [model] [args]  Start OpenAI-compatible API server (no model => fzf picker from llama list)"
    echo "  list [-a]              List local models (-a shows mmproj files)"
    echo "  pull <repo-or-url>     Pull model files (GGUF chooser; MLX repos auto-download fully)"
    echo "  rm|remove <model...>   Remove one or more models and their mmproj files"
    echo "  stop                   Stop running server"
    echo "  ps                     Show server status"
    echo "  logs [-f] [-n N]       Show/follow detached server logs"
    echo "  doctor [model] [--download-mmproj]  Check binaries, models dir, server health, and mmproj availability"
    echo "  config <key> ...       Set runtime env toggles without manual export"
    echo "  bench <model>          Run benchmark"
    echo "  speed <model> [--tokens N] [--runs N]   Measure generation speed via llama-cli"
    echo "  pipe <model> <instr> [file]  Pipe stdin or file into model with instruction"
    echo "  convert <hf-model-or-dir> [args]   Convert to GGUF (auto-detects assistant/MTP); use --full or --mtp to force mode"
    echo "  update-convert         Refresh conversion scripts from llama.cpp"
    echo "  check-convert          Verify conversion dependencies (python/torch/transformers/gguf)"
    echo "  opencode <model|sync> Register or sync models into OpenCode config"
    echo "  pi <model|sync>       Register or sync models into Pi config"
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
