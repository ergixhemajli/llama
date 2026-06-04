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
                        echo "[WARN] MTP mode: assistant directory found (${assistant_dir##*/}) but no assistant GGUF file"
                        echo "[INFO] MTP mode: llama.cpp needs assistant GGUF via --spec-draft-model"
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

_llama_bench() {
    local model_query="$1"
    [ -z "$model_query" ] && { echo "Usage: llama bench <model>"; return 1; }
    shift
    local model_path
    model_path=$(_llama_find_model "$model_query") || return 1
    local tech
    tech="$(_llama_model_tech_for_file "$model_path")"
    local user_set_ctk=0
    local user_set_ctv=0
    local arg
    for arg in "$@"; do
        case "$arg" in
            -ctk|--cache-type-k) user_set_ctk=1 ;;
            -ctv|--cache-type-v) user_set_ctv=1 ;;
        esac
    done
    echo "▶ Benchmarking: ${model_path##*/}"
    if [ "$tech" = "MTP" ]; then
        echo "  Runtime: GGUF + MTP model (llama-bench currently benchmarks plain decode path)"
    else
        echo "  Runtime: GGUF (plain)"
    fi
    local args=(
        -m "$model_path"
        -n 256
        -p 512
        -ngl "$LLM_DEFAULT_GPU_LAYERS"
    )
    [ "$user_set_ctk" = "0" ] && args+=(-ctk "$(_llama_resolve_cache_type_k)")
    [ "$user_set_ctv" = "0" ] && args+=(-ctv "$(_llama_resolve_cache_type_v)")
    llama-bench "${args[@]}" "$@"
}

_llama_speed() {
    local model_query="$1"
    [ -z "$model_query" ] && { echo "Usage: llama speed <model> [--tokens N] [--runs N]"; return 1; }
    shift

    local tokens=512
    local runs=1
    local passthrough=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tokens)
                shift
                tokens="${1:-512}"
                ;;
            --runs)
                shift
                runs="${1:-1}"
                ;;
            *)
                passthrough+=("$1")
                ;;
        esac
        shift
    done

    local model_path
    model_path=$(_llama_find_model "$model_query") || return 1
    _llama_model_meta_backfill_for_file "$model_path"

    local mmproj_path=""
    if mmproj_path=$(_llama_find_mmproj "$model_path" 2>/dev/null); then
        :
    fi

    local runtime_label="GGUF (plain - no MTP path found)"
    local args=(
        --model "$model_path"
        --ctx-size "$LLM_DEFAULT_CTX"
        --n-gpu-layers "$LLM_DEFAULT_GPU_LAYERS"
        --cache-type-k "$(_llama_resolve_cache_type_k)"
        --cache-type-v "$(_llama_resolve_cache_type_v)"
        --threads "$(_llama_cpu_threads)"
        --single-turn
        --no-display-prompt
        --log-disable
        --n-predict "$tokens"
        --prompt "Write one sentence about low-latency inference."
    )

    if _llama_binary_supports_mtp llama-cli; then
        local draft_model_path=""
        local assistant_dir=""
        if [ "$(_llama_model_tech_for_file "$model_path")" = "MTP" ]; then
            args+=(--spec-type draft-mtp --spec-draft-n-max "$_LLAMA_MTP_DRAFT_N_MAX")
            runtime_label="GGUF + MTP (embedded/marked, draft tokens: $_LLAMA_MTP_DRAFT_N_MAX)"
        elif draft_model_path=$(_llama_find_draft_model "$model_path"); then
            args+=(--spec-type draft-mtp --spec-draft-model "$draft_model_path" --spec-draft-n-max "$_LLAMA_MTP_DRAFT_N_MAX")
            runtime_label="GGUF + MTP (assistant: ${draft_model_path##*/}, draft tokens: $_LLAMA_MTP_DRAFT_N_MAX)"
        elif assistant_dir=$(_llama_find_local_assistant_dir_for_model "$model_path" 2>/dev/null); then
            local assistant_repo
            assistant_repo=$(_llama_infer_assistant_hf_repo_from_filename "${model_path##*/}")
            if [ -n "$assistant_repo" ] && command -v hf >/dev/null 2>&1; then
                local assistant_download_dir="$LLM_MODELS_DIR/.assistant-gguf"
                mkdir -p "$assistant_download_dir"
                local assistant_name="${assistant_repo##*/}.gguf"
                local assistant_gguf="$assistant_download_dir/$assistant_name"
                if [ ! -f "$assistant_gguf" ]; then
                    echo "  Assistant: downloading GGUF for MTP ($assistant_repo)..."
                    if hf download "$assistant_repo" --include "*.gguf" --local-dir "$assistant_download_dir" >/dev/null 2>&1; then
                        local first_gguf
                        first_gguf=$(find "$assistant_download_dir" -name "*.gguf" 2>/dev/null | sort | head -1)
                        [ -n "$first_gguf" ] && mv -f "$first_gguf" "$assistant_gguf"
                    fi
                fi
                if [ -f "$assistant_gguf" ]; then
                    args+=(--spec-type draft-mtp --spec-draft-model "$assistant_gguf" --spec-draft-n-max "$_LLAMA_MTP_DRAFT_N_MAX")
                    runtime_label="GGUF + MTP (assistant: ${assistant_gguf##*/}, draft tokens: $_LLAMA_MTP_DRAFT_N_MAX)"
                else
                    runtime_label="GGUF (plain - assistant dir present but assistant GGUF unavailable)"
                fi
            else
                runtime_label="GGUF (plain - assistant dir present but hf CLI/repo mapping unavailable)"
            fi
        fi
    else
        runtime_label="GGUF (plain - draft-mtp unavailable in llama.cpp binary)"
    fi

    [ -n "$mmproj_path" ] && args+=(--mmproj "$mmproj_path")

    echo "▶ Speed test: ${model_path##*/}"
    echo "  Runtime: $runtime_label"
    echo "  Tokens per run: $tokens"
    echo "  Runs: $runs"

    local run_idx out tps sum=0 count=0
    for ((run_idx=1; run_idx<=runs; run_idx++)); do
        echo "  Run $run_idx/$runs..."
        out=$(llama-cli "${args[@]}" "${passthrough[@]}" 2>&1)
        tps=$(printf '%s\n' "$out" | python3 -c '
import re,sys
s=sys.stdin.read()
m=re.findall(r"([0-9]+(?:\.[0-9]+)?)\s*tokens/s", s)
print(m[-1] if m else "")
')
        if [ -n "$tps" ]; then
            echo "    tokens/s: $tps"
            sum=$(python3 -c "print($sum + float('$tps'))")
            count=$((count + 1))
        else
            echo "    tokens/s: (not parsed; rerun with --verbose if needed)"
        fi
    done

    if [ "$count" -gt 0 ]; then
        local avg
        avg=$(python3 -c "print(round($sum / $count, 2))")
        echo "  Average tokens/s: $avg"
    fi
}

_llama_config() {
    local key="$1"
    local value="$2"

    case "$key" in
        show|""|-h|--help)
            echo ""
            echo "llama config"
            echo "  LLM_DEFAULT_CACHE_TYPE_K=$LLM_DEFAULT_CACHE_TYPE_K"
            echo "  LLM_DEFAULT_CACHE_TYPE_V=$LLM_DEFAULT_CACHE_TYPE_V"
            echo "  LLM_DEFAULT_THREADS=${LLM_DEFAULT_THREADS:-<auto p-cores>}"
            echo "  LLM_PIPE_N_PREDICT=$LLM_PIPE_N_PREDICT"
            echo "  LLM_NO_THINKING=$LLM_NO_THINKING"
            echo ""
            echo "Usage:"
            echo "  llama config threads <n|auto>"
            echo "  llama config cache <type>"
            echo "  llama config pipe-n <n>"
            echo "  llama config no-thinking <on|off>"
            echo "  llama config save [file]"
            echo "  llama config load [file]"
            echo ""
            ;;
        threads)
            if [[ "$value" == "auto" || -z "$value" ]]; then
                export LLM_DEFAULT_THREADS=""
                echo "✓ LLM_DEFAULT_THREADS=<auto p-cores>"
            elif [[ "$value" =~ ^[0-9]+$ ]]; then
                export LLM_DEFAULT_THREADS="$value"
                echo "✓ LLM_DEFAULT_THREADS=$LLM_DEFAULT_THREADS"
            else
                echo "Usage: llama config threads <n|auto>"
                return 1
            fi
            ;;
        cache)
            [ -z "$value" ] && { echo "Usage: llama config cache <type>"; return 1; }
            export LLM_DEFAULT_CACHE_TYPE_K="$value"
            export LLM_DEFAULT_CACHE_TYPE_V="$value"
            echo "✓ LLM_DEFAULT_CACHE_TYPE_K=$LLM_DEFAULT_CACHE_TYPE_K"
            echo "✓ LLM_DEFAULT_CACHE_TYPE_V=$LLM_DEFAULT_CACHE_TYPE_V"
            ;;
        pipe-n)
            if [[ "$value" =~ ^[0-9]+$ ]]; then
                export LLM_PIPE_N_PREDICT="$value"
                echo "✓ LLM_PIPE_N_PREDICT=$LLM_PIPE_N_PREDICT"
            else
                echo "Usage: llama config pipe-n <n>"
                return 1
            fi
            ;;
        no-thinking)
            case "$value" in
                on|1|true|yes)
                    export LLM_NO_THINKING="1"
                    echo "✓ LLM_NO_THINKING=$LLM_NO_THINKING"
                    ;;
                off|0|false|no|"")
                    export LLM_NO_THINKING="0"
                    echo "✓ LLM_NO_THINKING=$LLM_NO_THINKING"
                    ;;
                *)
                    echo "Usage: llama config no-thinking <on|off>"
                    return 1
                    ;;
            esac
            ;;
        save)
            local out_file="${value:-$LLM_RUNTIME_CONFIG_FILE}"
            mkdir -p "$(dirname "$out_file")"
            cat > "$out_file" <<EOF
# Generated by llama config save
export LLM_DEFAULT_CACHE_TYPE_K="${LLM_DEFAULT_CACHE_TYPE_K}"
export LLM_DEFAULT_CACHE_TYPE_V="${LLM_DEFAULT_CACHE_TYPE_V}"
export LLM_DEFAULT_THREADS="${LLM_DEFAULT_THREADS}"
export LLM_PIPE_N_PREDICT="${LLM_PIPE_N_PREDICT}"
export LLM_NO_THINKING="${LLM_NO_THINKING}"
EOF
            echo "✓ Saved runtime config to: $out_file"
            if [ "$out_file" = "$LLM_RUNTIME_CONFIG_FILE" ]; then
                echo "  This file is auto-loaded when llama-aliases.sh is sourced."
            else
                echo "  Load this custom file with: llama config load \"$out_file\""
            fi
            ;;
        load)
            local in_file="${value:-$LLM_RUNTIME_CONFIG_FILE}"
            if [ ! -f "$in_file" ]; then
                echo "Config file not found: $in_file"
                return 1
            fi
            # shellcheck disable=SC1090
            source "$in_file"
            echo "✓ Loaded runtime config from: $in_file"
            echo "  Run 'llama config show' to verify"
            ;;
        *)
            echo "Unknown config key: $key"
            echo "Run: llama config show"
            return 1
            ;;
    esac
}

_llama_register_opencode() {
    local filename="$1"
    local model_id="${filename%.gguf}"
    local config_file="$HOME/.config/opencode/opencode.json"
    [ ! -f "$config_file" ] && return

    python3 -c "
import json, sys
config_path = sys.argv[1]
model_id = sys.argv[2]
try:
    with open(config_path, 'r') as f:
        config = json.load(f)
    models = config.setdefault('provider', {}).setdefault('llama.cpp', {}).setdefault('models', {})
    if model_id not in models:
        friendly = model_id.replace('-UD-Q4_K_XL', '').replace('-Q4_K_M', '').replace('-Q5_K_M', '').replace('-Q8_0', '')
        friendly = ' '.join(friendly.split('-'))
        models[model_id] = {
            'name': f'{friendly} (local)',
            'limit': {'context': 32768, 'output': 8192}
        }
        with open(config_path, 'w') as f:
            json.dump(config, f, indent=2)
        print(f'  Registered {model_id} in opencode config')
except Exception as e:
    print(f'  Warning: could not register model: {e}', file=sys.stderr)
" "$config_file" "$model_id" 2>/dev/null
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

if [[ -n "$LLM_RUNTIME_CONFIG_FILE" && -f "$LLM_RUNTIME_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$LLM_RUNTIME_CONFIG_FILE"
fi

llama-speed() {
    _llama_speed "$@"
}

llama-pipe() {
    _llama_pipe "$@"
}
