#!/usr/bin/env bash
# llama-server.sh — Run, serve, stop, ps commands

_llama_run() {
    local force_mlx=0
    local no_thinking="$LLM_NO_THINKING"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mlx)
                force_mlx=1
                shift
                ;;
            --no-thinking)
                no_thinking=1
                shift
                ;;
            --thinking)
                no_thinking=0
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    local model_query="$1"; shift
    [ -z "$model_query" ] && { echo "Usage: llama run [--no-thinking] <model> [args]"; return 1; }

    if [ "$force_mlx" = "1" ]; then
        if ! command -v python3 >/dev/null 2>&1; then
            echo "Error: python3 is required for MLX mode" >&2
            return 1
        fi
        if _llama_bool_is_true "$no_thinking"; then
            echo "  Note: --no-thinking is currently ignored for MLX mode"
        fi
        echo "  Runtime: MLX"
        echo "▶ Running MLX model: $model_query"
        python3 -m "$_LLAMA_MLX_CHAT_MODULE" --model "$model_query" "$@"
        return $?
    fi

    local model_path
    if model_path=$(_llama_find_model "$model_query" 2>/dev/null); then
        _llama_model_meta_backfill_for_file "$model_path"
        :
    elif [[ "$model_query" == */* ]]; then
        if ! command -v python3 >/dev/null 2>&1; then
            echo "Error: python3 is required for MLX mode" >&2
            return 1
        fi
        if _llama_bool_is_true "$no_thinking"; then
            echo "  Note: --no-thinking is currently ignored for MLX mode"
        fi
        echo "  Runtime: MLX"
        echo "▶ Running MLX model: $model_query"
        python3 -m "$_LLAMA_MLX_CHAT_MODULE" --model "$model_query" "$@"
        return $?
    else
        _llama_find_model "$model_query"
        return 1
    fi

    local mmproj_path=""
    if mmproj_path=$(_llama_find_mmproj "$model_path"); then
        echo "  Vision projector: ${mmproj_path##*/}"
    fi
    local runtime_label="GGUF (plain - no MTP path found)"
    local assistant_dir=""
    assistant_dir=$(_llama_find_local_assistant_dir_for_model "$model_path" || true)
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
    if _llama_binary_supports_mtp llama-cli; then
        local draft_model_path=""
        local assistant_gguf=""
        if [ "$(_llama_model_tech_for_file "$model_path")" = "MTP" ]; then
            args+=(--spec-type draft-mtp --spec-draft-n-max "$_LLAMA_MTP_DRAFT_N_MAX")
            runtime_label="GGUF + MTP (embedded, draft tokens: $_LLAMA_MTP_DRAFT_N_MAX)"
        elif draft_model_path=$(_llama_find_draft_model "$model_path"); then
            args+=(--spec-type draft-mtp --spec-draft-model "$draft_model_path" --spec-draft-n-max "$_LLAMA_MTP_DRAFT_N_MAX")
            runtime_label="GGUF + MTP (assistant: ${draft_model_path##*/}, draft tokens: $_LLAMA_MTP_DRAFT_N_MAX)"
        elif _llama_binary_supports_gemma_assistant llama-cli && assistant_gguf=$(_llama_resolve_assistant_gguf_for_model "$model_path" 2>/dev/null); then
            args+=(--spec-type draft-mtp --spec-draft-model "$assistant_gguf" --spec-draft-n-max "$_LLAMA_MTP_DRAFT_N_MAX")
            runtime_label="GGUF + MTP (assistant: ${assistant_gguf##*/}, draft tokens: $_LLAMA_MTP_DRAFT_N_MAX)"
        elif [ -n "$assistant_dir" ]; then
            if _llama_binary_supports_gemma_assistant llama-cli; then
                runtime_label="GGUF (plain - assistant dir present: ${assistant_dir##*/}, assistant GGUF unresolved)"
            else
                runtime_label="GGUF (plain - assistant dir present: ${assistant_dir##*/}, llama.cpp lacks gemma4_assistant support)"
            fi
        fi
    else
        runtime_label="GGUF (plain - draft-mtp unavailable in llama.cpp binary)"
    fi
    echo "  Runtime: $runtime_label"
    _llama_bool_is_true "$no_thinking" && args+=(--chat-template-kwargs '{"enable_thinking":false}')
    [ -n "$mmproj_path" ] && args+=(--mmproj "$mmproj_path")
    llama-cli "${args[@]}" "$@"
}

_llama_serve() {
    local detach=0
    local no_thinking="$LLM_NO_THINKING"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--detach)
                detach=1
                shift
                ;;
            --no-thinking)
                no_thinking=1
                shift
                ;;
            --thinking)
                no_thinking=0
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    local model_query="$1"; shift
    [ -z "$model_query" ] && { echo "Usage: llama serve [-d] [--no-thinking] <model> [args]"; return 1; }

    local passthrough=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--detach) detach=1 ;;
            --no-thinking) no_thinking=1 ;;
            --thinking) no_thinking=0 ;;
            *) passthrough+=("$1") ;;
        esac
        shift
    done

    local model_path
    model_path=$(_llama_find_model "$model_query") || return 1
    _llama_model_meta_backfill_for_file "$model_path"
    local mmproj_path
    mmproj_path=$(_llama_find_mmproj "$model_path") || {
        local _base; _base=$(basename "$model_path" .gguf)
        local _stripped; _stripped=$(echo "$_base" | sed -E 's/[-_]((UD|UDT)-)?Q[0-9]+_[A-Z0-9]+(_[A-Z0-9]+)*$//')
        echo "  WARNING: No mmproj found for $model_path"
        echo "  Expected: mmproj-F16-${_stripped}.gguf"
        mmproj_path=""
    }
    [ -n "$mmproj_path" ] && echo "  Vision projector: ${mmproj_path##*/}"
    local runtime_label="GGUF (plain - no MTP path found)"
    local assistant_dir=""
    assistant_dir=$(_llama_find_local_assistant_dir_for_model "$model_path" || true)
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
    if _llama_binary_supports_mtp llama-server; then
        local draft_model_path=""
        local assistant_gguf=""
        if [ "$(_llama_model_tech_for_file "$model_path")" = "MTP" ]; then
            args+=(--spec-type draft-mtp --spec-draft-n-max "$_LLAMA_MTP_DRAFT_N_MAX")
            runtime_label="GGUF + MTP (embedded, draft tokens: $_LLAMA_MTP_DRAFT_N_MAX)"
        elif draft_model_path=$(_llama_find_draft_model "$model_path"); then
            args+=(--spec-type draft-mtp --spec-draft-model "$draft_model_path" --spec-draft-n-max "$_LLAMA_MTP_DRAFT_N_MAX")
            runtime_label="GGUF + MTP (assistant: ${draft_model_path##*/}, draft tokens: $_LLAMA_MTP_DRAFT_N_MAX)"
        elif _llama_binary_supports_gemma_assistant llama-server && assistant_gguf=$(_llama_resolve_assistant_gguf_for_model "$model_path" 2>/dev/null); then
            args+=(--spec-type draft-mtp --spec-draft-model "$assistant_gguf" --spec-draft-n-max "$_LLAMA_MTP_DRAFT_N_MAX")
            runtime_label="GGUF + MTP (assistant: ${assistant_gguf##*/}, draft tokens: $_LLAMA_MTP_DRAFT_N_MAX)"
        elif [ -n "$assistant_dir" ]; then
            if _llama_binary_supports_gemma_assistant llama-server; then
                runtime_label="GGUF (plain - assistant dir present: ${assistant_dir##*/}, assistant GGUF unresolved)"
            else
                runtime_label="GGUF (plain - assistant dir present: ${assistant_dir##*/}, llama.cpp lacks gemma4_assistant support)"
            fi
        fi
    else
        runtime_label="GGUF (plain - draft-mtp unavailable in llama.cpp binary)"
    fi
    echo "  Runtime: $runtime_label"
    _llama_bool_is_true "$no_thinking" && args+=(--chat-template-kwargs '{"enable_thinking":false}')
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
    echo "llama ps"
    echo ""
    if _llama_server_running; then
        local endpoint="http://${LLM_SERVER_HOST}:${LLM_SERVER_PORT}"
        local pids
        pids=$(pgrep -f "llama-server" 2>/dev/null)

        printf "  %-10s %s\n" "Status" "running"
        printf "  %-10s %s\n" "Endpoint" "$endpoint"
        printf "  %-10s %s\n" "PID(s)" "$(echo $pids | tr '\n' ' ')"
        local loaded_models
        loaded_models=$(curl -sf "http://${LLM_SERVER_HOST}:${LLM_SERVER_PORT}/v1/models" 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    models = [m.get("id", "?") for m in data.get("data", [])]
    for m in models:
        print(m)
except Exception:
    pass
' 2>/dev/null)
        if [ -n "$loaded_models" ]; then
            local first=1
            while IFS= read -r model_id; do
                [ -z "$model_id" ] && continue
                if [ "$first" = "1" ]; then
                    printf "  %-10s %s\n" "Model(s)" "$model_id"
                    first=0
                else
                    printf "  %-10s %s\n" "" "$model_id"
                fi
            done <<< "$loaded_models"
        fi
        echo ""

        if [ -n "$pids" ]; then
            echo "  Process metrics"
            echo "  ---------------------------------------------"
            echo "  PID    CPU%   MEM%   MEM(GB)   ELAPSED"
            local total_ram_gb
            total_ram_gb=$(python3 -c "import subprocess; v=subprocess.check_output(['sysctl','-n','hw.memsize']).decode().strip(); print(round(int(v)/(1024**3),1))" 2>/dev/null)
            while IFS= read -r pid; do
                [ -z "$pid" ] && continue
                ps -p "$pid" -o pid=,pcpu=,pmem=,rss=,etime= | python3 -c '
import sys
line=sys.stdin.read().strip()
if not line:
    raise SystemExit(0)
parts=line.split()
if len(parts) < 5:
    raise SystemExit(0)
pid, cpu_s, mem_s, rss_kb_s, elapsed = parts[0], parts[1], parts[2], parts[3], parts[4]
cpu=float(cpu_s.replace(",","."))
mem=float(mem_s.replace(",","."))
rss_gb=int(rss_kb_s)/(1024*1024)
print(f"  {pid:<6} {cpu:>5.1f}  {mem:>5.1f}  {rss_gb:>7.2f}   {elapsed}")
' 2>/dev/null
            done <<< "$pids"
            echo "  ---------------------------------------------"
        fi

    else
        printf "  %-10s %s\n" "Status" "not running"
    fi
    echo ""
}
