#!/usr/bin/env bash

LLM_MODELS_DIR="${LLM_MODELS_DIR:-$HOME/.llama/llama-models}"
LLM_DEFAULT_CTX="${LLM_DEFAULT_CTX:-32768}"
LLM_DEFAULT_GPU_LAYERS="${LLM_DEFAULT_GPU_LAYERS:-99}"
LLM_SERVER_HOST="${LLM_SERVER_HOST:-127.0.0.1}"
LLM_SERVER_PORT="${LLM_SERVER_PORT:-11434}"
LLM_HF_DEFAULT_USER="${LLM_HF_DEFAULT_USER:-unsloth}"
LLM_DEFAULT_CACHE_TYPE_K="${LLM_DEFAULT_CACHE_TYPE_K:-f16}"
LLM_DEFAULT_CACHE_TYPE_V="${LLM_DEFAULT_CACHE_TYPE_V:-f16}"
LLM_RUNTIME_CONFIG_FILE="${LLM_RUNTIME_CONFIG_FILE:-$HOME/.llama/llama-runtime.env}"
LLM_DEFAULT_THREADS="${LLM_DEFAULT_THREADS:-}"
LLM_ASK_N_PREDICT="${LLM_ASK_N_PREDICT:-1024}"
LLM_ASK_REASONING="${LLM_ASK_REASONING:-off}"
LLM_ASK_IGNORE_EOS="${LLM_ASK_IGNORE_EOS:-0}"
LLM_PIPE_N_PREDICT="${LLM_PIPE_N_PREDICT:-4096}"

_llama_resolve_cache_type_k() { echo "$LLM_DEFAULT_CACHE_TYPE_K"; }
_llama_resolve_cache_type_v() { echo "$LLM_DEFAULT_CACHE_TYPE_V"; }

_llama_find_model() {
    local query="$1"
    [ -z "$query" ] && { echo "Error: no model specified" >&2; return 1; }
    if [ -f "$query" ]; then echo "$query"; return 0; fi
    local exact="$LLM_MODELS_DIR/$query"
    [ -f "$exact" ] && { echo "$exact"; return 0; }
    local exact_gguf="$LLM_MODELS_DIR/${query}.gguf"
    [ -f "$exact_gguf" ] && { echo "$exact_gguf"; return 0; }
    local fuzzy
    fuzzy=$(find "$LLM_MODELS_DIR" -iname "*${query}*.gguf" 2>/dev/null | sort | head -1)
    if [ -n "$fuzzy" ]; then echo "$fuzzy"; return 0; fi
    echo "Error: model '$query' not found in $LLM_MODELS_DIR" >&2
    return 1
}

_llama_find_mmproj() {
    local model_path="$1"
    local base="${model_path##*/}"
    base="${base%.gguf}"

    local candidate="$LLM_MODELS_DIR/mmproj-F16-${base}.gguf"
    [ -f "$candidate" ] && { echo "$candidate"; return 0; }

    local stripped
    stripped=$(echo "$base" | sed -E 's/[-_]((UD|UDT)-)?Q[0-9]+_[A-Z0-9]+(_[A-Z0-9]+)*$//')
    candidate="$LLM_MODELS_DIR/mmproj-F16-${stripped}.gguf"
    [ -f "$candidate" ] && { echo "$candidate"; return 0; }

    local fuzzy
    fuzzy=$(find "$LLM_MODELS_DIR" -iname "mmproj-F16-${stripped}*.gguf" 2>/dev/null | head -1)
    [ -n "$fuzzy" ] && { echo "$fuzzy"; return 0; }
    return 1
}

_llama_server_running() {
    curl -sf "http://${LLM_SERVER_HOST}:${LLM_SERVER_PORT}/health" > /dev/null 2>&1
}

_llama_cpu_threads() {
    if [ -n "$LLM_DEFAULT_THREADS" ]; then
        echo "$LLM_DEFAULT_THREADS"
        return
    fi

    local pcores
    pcores=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || true)
    if [ -n "$pcores" ]; then
        echo "$pcores"
        return
    fi

    nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4
}

_llama_supports_reasoning() {
    llama-cli --help 2>/dev/null | grep -q -- "--reasoning"
}

_llama_spinner_char() {
    case $(( $1 % 4 )) in
        0) printf '|' ;;
        1) printf '/' ;;
        2) printf '-' ;;
        3) printf '\\' ;;
    esac
}

_llama_run() {
    local model_query="$1"; shift
    local model_path
    model_path=$(_llama_find_model "$model_query") || return 1
    local mmproj_path=""
    if mmproj_path=$(_llama_find_mmproj "$model_path"); then
        echo "  Vision projector: ${mmproj_path##*/}"
    fi
    echo "▶ Running: ${model_path##*/}"
    local args=(
        --model "$model_path"
        --ctx-size "$LLM_DEFAULT_CTX"
        --n-gpu-layers "$LLM_DEFAULT_GPU_LAYERS"
        --cache-type-k "$(_llama_resolve_cache_type_k)"
        --cache-type-v "$(_llama_resolve_cache_type_v)"
        --threads "$(_llama_cpu_threads)"
        -cnv
    )
    [ -n "$mmproj_path" ] && args+=(--mmproj "$mmproj_path")
    llama-cli "${args[@]}" "$@"
}

_llama_serve() {
    local detach=0
    if [[ "$1" == "-d" || "$1" == "--detach" ]]; then
        detach=1
        shift
    fi

    local model_query="$1"; shift
    local passthrough=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--detach) detach=1 ;;
            *) passthrough+=("$1") ;;
        esac
        shift
    done

    local model_path
    model_path=$(_llama_find_model "$model_query") || return 1
    local mmproj_path
    mmproj_path=$(_llama_find_mmproj "$model_path") || {
        local _base; _base=$(basename "$model_path" .gguf)
        local _stripped; _stripped=$(echo "$_base" | sed -E 's/[-_]((UD|UDT)-)?Q[0-9]+_[A-Z0-9]+(_[A-Z0-9]+)*$//')
        echo "  WARNING: No mmproj found for $model_path"
        echo "  Expected: mmproj-F16-${_stripped}.gguf"
        mmproj_path=""
    }
    [ -n "$mmproj_path" ] && echo "  Vision projector: ${mmproj_path##*/}"
    echo "▶ Serving: ${model_path##*/}"

    local args=(
        --model "$model_path"
        --ctx-size "$LLM_DEFAULT_CTX"
        --n-gpu-layers "$LLM_DEFAULT_GPU_LAYERS"
        --cache-type-k "$(_llama_resolve_cache_type_k)"
        --cache-type-v "$(_llama_resolve_cache_type_v)"
        --threads "$(_llama_cpu_threads)"
        --host "$LLM_SERVER_HOST"
        --port "$LLM_SERVER_PORT"
    )
    [ -n "$mmproj_path" ] && args+=(--mmproj "$mmproj_path")

    if [ "$detach" = "1" ]; then
        local log_file="${LLM_SERVER_LOG_FILE:-$HOME/.llama/llama-server.log}"
        local ready_timeout="${LLM_SERVER_READY_TIMEOUT:-30}"
        local min_spinner_steps="${LLM_SERVER_MIN_SPINNER_STEPS:-3}"
        mkdir -p "$(dirname "$log_file")"
        : > "$log_file"
        nohup llama-server "${args[@]}" "${passthrough[@]}" > "$log_file" 2>&1 &
        local pid=$!
        disown "$pid" 2>/dev/null || true
        local i=0
        local start_time=$SECONDS
        while true; do
            printf "\r▶ Starting server in background %s" "$(_llama_spinner_char "$i")"
            i=$((i + 1))
            if _llama_server_running && [ "$i" -ge "$min_spinner_steps" ]; then
                printf "\r✓ Server is ready for requests                      \n"
                echo "  PID: $pid"
                echo "  URL: http://${LLM_SERVER_HOST}:${LLM_SERVER_PORT}"
                echo "  Log: $log_file"
                break
            fi
            if ! kill -0 "$pid" 2>/dev/null; then
                printf "\r✗ Server exited before becoming ready               \n"
                echo "  PID: $pid"
                echo "  Log: $log_file"
                return 1
            fi
            if [ $((SECONDS - start_time)) -ge "$ready_timeout" ]; then
                printf "\r! Server still starting (timeout ${ready_timeout}s) \n"
                echo "  PID: $pid"
                echo "  URL: http://${LLM_SERVER_HOST}:${LLM_SERVER_PORT}"
                echo "  Log: $log_file"
                break
            fi
            sleep 0.2
        done
    else
        llama-server "${args[@]}" "${passthrough[@]}"
    fi
}

_llama_list() {
    local show_all=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--all) show_all=true; shift ;;
            *) shift ;;
        esac
    done
    echo ""
    printf "%-50s %-10s %s\n" "NAME" "SIZE" "PATH"
    printf "%-50s %-10s %s\n" "────────────────────────────────────────────────" "──────────" "────────────────────────────"
    find "$LLM_MODELS_DIR" -name "*.gguf" 2>/dev/null | sort | while IFS= read -r f; do
        local bname="${f##*/}"
        [[ "$show_all" == false && "$bname" == mmproj* ]] && continue
        printf "%-50s %-10s %s\n" "${bname%.gguf}" "$(du -sh "$f" 2>/dev/null | awk '{print $1}')" "$f"
    done
    echo ""
}

_llama_pull() {
    local target="$1"
    [ -z "$target" ] && { echo "Usage: llama pull <huggingface-repo-or-url>"; return 1; }
    mkdir -p "$LLM_MODELS_DIR"

    local hf_repo=""
    local direct_url=""

    if [[ "$target" == http* ]]; then
        if [[ "$target" == *.gguf ]]; then
            direct_url="$target"
        elif [[ "$target" == *"huggingface.co/"* ]]; then
            hf_repo="${target#*huggingface.co/}"
            hf_repo="${hf_repo%/}"
            hf_repo="${hf_repo%%\?*}"
        else
            direct_url="$target"
        fi
    else
        if [[ "$target" == */* ]]; then
            hf_repo="$target"
        else
            hf_repo="${LLM_HF_DEFAULT_USER}/${target}"
        fi
    fi

    if [ -n "$direct_url" ]; then
        local filename="${direct_url##*/}"
        filename="${filename%%\?*}"
        [ -z "$filename" ] && filename="model.gguf"
        echo "▶ Downloading $filename…"
        curl -L --progress-bar -o "$LLM_MODELS_DIR/$filename" "$direct_url"
        echo "✓ Saved to $LLM_MODELS_DIR/$filename"
        return
    fi

    [ -z "$hf_repo" ] && { echo "Error: Could not determine Hugging Face repo."; return 1; }

    echo "▶ Fetching file list from huggingface.co/$hf_repo…"
    local api_url="https://huggingface.co/api/models/${hf_repo}"
    local files
    files=$(curl -sf "$api_url" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    siblings = data.get('siblings', [])
    ggufs = [f['rfilename'] for f in siblings if f['rfilename'].endswith('.gguf') and not f['rfilename'].startswith('mmproj')]
    for f in sorted(ggufs): print(f)
except Exception:
    sys.exit(1)
" 2>/dev/null)

    if [ -z "$files" ]; then
        echo "Error: no GGUF files found in $hf_repo"
        return 1
    fi

    echo ""
    echo "Available GGUF files in $hf_repo:"
    local i=1
    local file_arr=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo "  [$i] $line"
        file_arr+=("$line")
        ((i++))
    done <<< "$files"
    echo ""
    printf "Select file number [default: 1]: "
    read -r choice
    choice="${choice:-1}"
    local chosen
    if [ -n "$ZSH_VERSION" ]; then
        chosen="${file_arr[$choice]}"
    else
        chosen="${file_arr[$((choice-1))]}"
    fi
    [ -z "$chosen" ] && { echo "Invalid selection."; return 1; }

    local dl_url="https://huggingface.co/${hf_repo}/resolve/main/${chosen}"
    local filename="${chosen##*/}"
    local out_file="$LLM_MODELS_DIR/$filename"
    echo "▶ Downloading $chosen…"
    curl -L --progress-bar -o "$out_file" "$dl_url"
    echo "✓ Saved to $out_file"

    if [[ "$filename" != mmproj* ]]; then
        _llama_register_opencode "$filename"
    fi

    if [[ "$filename" != mmproj* ]]; then
        local mmproj_remote="mmproj-F16.gguf"
        local http_status
        http_status=$(curl -sf -o /dev/null -w "%{http_code}" -L --max-time 5 "https://huggingface.co/${hf_repo}/resolve/main/${mmproj_remote}" 2>/dev/null)
        if [ "$http_status" = "200" ]; then
            local model_base="${filename%.gguf}"
            local stripped_base
            stripped_base=$(echo "$model_base" | sed -E 's/[-_]((UD|UDT)-)?Q[0-9]+_[A-Z0-9]+(_[A-Z0-9]+)*$//')
            local mmproj_out="$LLM_MODELS_DIR/mmproj-F16-${stripped_base}.gguf"
            echo ""
            printf "Vision projector (mmproj-F16) found — download it? [Y/n] "
            read -r mmproj_confirm
            if [[ "${mmproj_confirm:-Y}" =~ ^[Yy]$ ]]; then
                echo "▶ Downloading mmproj-F16 -> ${mmproj_out##*/}…"
                curl -L --progress-bar -o "$mmproj_out" "https://huggingface.co/${hf_repo}/resolve/main/${mmproj_remote}"
                echo "✓ Saved to $mmproj_out"
            fi
        fi
    fi
}

_llama_rm() {
    local model_query="$1"
    [ -z "$model_query" ] && { echo "Usage: llama remove|rm <model>"; return 1; }
    local model_path
    model_path=$(_llama_find_model "$model_query") || return 1

    local mmproj_path
    mmproj_path=$(_llama_find_mmproj "$model_path" 2>/dev/null || echo "")

    echo "🗑  Target: ${model_path##*/}"
    if [ -f "$mmproj_path" ]; then
        echo "🗑  Vision: ${mmproj_path##*/}"
    fi

    printf "Delete these files? [y/N] "
    read -r confirm
    if [[ "${confirm:-n}" =~ ^[Yy]$ ]]; then
        rm -v "$model_path" 2>&1 | sed 's|^.*|  ✓ Removed |'
        if [ -f "$mmproj_path" ]; then
            rm -v "$mmproj_path" 2>&1 | sed 's|^.*|  ✓ Removed |'
        fi
    fi
}

_llama_stop() {
    if _llama_server_running; then
        local pids
        pids=$(pgrep -f "llama-server" 2>/dev/null)
        if [ -n "$pids" ]; then
            echo "▶ Stopping llama-server (PID(s): $(echo $pids | tr '\n' ' '))"
            echo "$pids" | xargs kill 2>/dev/null
            sleep 1
            if pgrep -f "llama-server" > /dev/null 2>&1; then
                echo "$pids" | xargs kill -9 2>/dev/null
            fi
            echo "✓ Server stopped"
        fi
    else
        echo "No server running on http://${LLM_SERVER_HOST}:${LLM_SERVER_PORT}"
    fi
}

_llama_ps() {
    echo ""
    if _llama_server_running; then
        echo "Server is running at http://${LLM_SERVER_HOST}:${LLM_SERVER_PORT}"
        echo ""
        local pids
        pids=$(pgrep -f "llama-server" 2>/dev/null)
        if [ -n "$pids" ]; then
            echo "PID(s): $(echo $pids | tr '\n' ' ')"
            echo ""
            echo "Runtime usage (CPU/MEM/ELAPSED):"
            echo "  PID   CPU%   MEM%   RSS(MB)   ELAPSED"
            while IFS= read -r pid; do
                [ -z "$pid" ] && continue
                ps -p "$pid" -o pid=,pcpu=,pmem=,rss=,etime= | awk '{printf "  %-5s %-6s %-6s %-9.1f %s\n", $1, $2, $3, $4/1024, $5}'
            done <<< "$pids"
        fi
        if command -v memory_pressure >/dev/null 2>&1; then
            local mem_free
            mem_free=$(memory_pressure 2>/dev/null | awk -F': ' '/System-wide memory free percentage/ {print $2; exit}')
            [ -n "$mem_free" ] && echo "Memory pressure: free ${mem_free}"
        fi
        echo ""
        curl -sf "http://${LLM_SERVER_HOST}:${LLM_SERVER_PORT}/v1/models" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for m in data.get('data', []):
        print(f\"  Model: {m.get('id', '?')}\")
except:
    pass
" 2>/dev/null
    else
        echo "No server running."
    fi
    echo ""
}
