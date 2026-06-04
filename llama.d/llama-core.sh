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
LLM_PIPE_N_PREDICT="${LLM_PIPE_N_PREDICT:-4096}"
LLM_NO_THINKING="${LLM_NO_THINKING:-0}"

_LLAMA_MTP_DRAFT_N_MAX=2
_LLAMA_MLX_CHAT_MODULE="mlx_vlm.chat"
_LLAMA_MODEL_INDEX_FILE="$LLM_MODELS_DIR/.llama-model-index.json"

_llama_resolve_cache_type_k() { echo "$LLM_DEFAULT_CACHE_TYPE_K"; }
_llama_resolve_cache_type_v() { echo "$LLM_DEFAULT_CACHE_TYPE_V"; }

_llama_bool_is_true() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

_llama_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

_llama_model_supports_mtp() {
    local model_ref="$1"
    [ "$(_llama_model_tech_for_file "$model_ref")" = "MTP" ]
}

_llama_repo_provider() {
    local repo="$1"
    [ -z "$repo" ] && return
    echo "${repo%%/*}"
}

_llama_repo_tech() {
    local repo_lc
    repo_lc="$(_llama_lower "$1")"
    case "$repo_lc" in
        *mlx*) echo "MLX" ;;
        *mtp*) echo "MTP" ;;
        *) echo "GGUF" ;;
    esac
}

_llama_model_meta_get_field() {
    local filename="$1"
    local field="$2"
    [ -f "$_LLAMA_MODEL_INDEX_FILE" ] || return
    python3 -c '
import json,sys
idx=sys.argv[1]; fn=sys.argv[2]; fld=sys.argv[3]
try:
    data=json.load(open(idx))
    val=data.get("models",{}).get(fn,{}).get(fld,"")
    if val: print(val)
except Exception:
    pass
' "$_LLAMA_MODEL_INDEX_FILE" "$filename" "$field" 2>/dev/null
}

_llama_model_meta_set() {
    local filename="$1"
    local repo="$2"
    local tech="$3"
    [ -z "$filename" ] && return
    mkdir -p "$LLM_MODELS_DIR"
    python3 -c '
import json,sys,os
idx,fn,repo,tech=sys.argv[1:5]
data={"models":{}}
if os.path.exists(idx):
    try: data=json.load(open(idx))
    except Exception: data={"models":{}}
models=data.setdefault("models",{})
meta=models.setdefault(fn,{})
if repo: meta["repo"]=repo
if tech: meta["tech"]=tech
if repo and "provider" not in meta:
    meta["provider"]=repo.split("/",1)[0]
with open(idx,"w") as f: json.dump(data,f,indent=2,sort_keys=True)
' "$_LLAMA_MODEL_INDEX_FILE" "$filename" "$repo" "$tech" 2>/dev/null
}

_llama_model_base_no_quant() {
    local filename="$1"
    local stem="${filename%.gguf}"
    _llama_model_strip_quant "$stem"
}

_llama_model_meta_backfill_for_file() {
    local model_ref="$1"
    local filename="${model_ref##*/}"
    [ -n "$filename" ] || return
    [ -n "$(_llama_model_meta_get_field "$filename" repo)" ] && return

    case "$filename" in
        Qwen3.6-27B-*.gguf)
            _llama_model_meta_set "$filename" "unsloth/Qwen3.6-27B-MTP-GGUF" "MTP"
            ;;
        Qwen3.6-35B-A3B-*.gguf)
            _llama_model_meta_set "$filename" "unsloth/Qwen3.6-35B-A3B-MTP-GGUF" "MTP"
            ;;
    esac
}

_llama_model_meta_remove() {
    local filename="$1"
    [ -f "$_LLAMA_MODEL_INDEX_FILE" ] || return
    python3 -c '
import json,sys,os
idx,fn=sys.argv[1:3]
if not os.path.exists(idx): raise SystemExit(0)
try: data=json.load(open(idx))
except Exception: raise SystemExit(0)
models=data.get("models",{})
if fn in models:
    del models[fn]
    with open(idx,"w") as f: json.dump(data,f,indent=2,sort_keys=True)
' "$_LLAMA_MODEL_INDEX_FILE" "$filename" 2>/dev/null
}

_llama_model_label() {
    local model_ref="$1"
    local filename="${model_ref##*/}"
    _llama_model_meta_backfill_for_file "$model_ref"
    local repo
    repo=$(_llama_model_meta_get_field "$filename" repo)
    if [ -n "$repo" ]; then
        echo "${repo##*/}"
    else
        echo "${filename%.gguf}"
    fi
}

_llama_model_provider_for_file() {
    local model_ref="$1"
    local filename="${model_ref##*/}"
    _llama_model_meta_backfill_for_file "$model_ref"
    local provider
    provider=$(_llama_model_meta_get_field "$filename" provider)
    [ -z "$provider" ] && provider="local"
    echo "$provider"
}

_llama_model_tech_for_file() {
    local model_ref="$1"
    local filename="${model_ref##*/}"
    _llama_model_meta_backfill_for_file "$model_ref"
    local tech
    tech=$(_llama_model_meta_get_field "$filename" tech)
    if [ -n "$tech" ]; then
        echo "$tech"
        return
    fi
    case "$(_llama_lower "${filename%.gguf}")" in
        *mtp*) echo "MTP" ;;
        *) echo "GGUF" ;;
    esac
}

_llama_model_strip_quant() {
    echo "$1" | sed -E 's/[-_]((UD|UDT)-)?(IQ[0-9]+_[A-Z0-9]+|Q[0-9]+_[A-Z0-9]+|Q[0-9]+_[A-Z0-9]+_[A-Z0-9]+|Q[0-9]+_[0-9]+|BF16|F16)$//'
}

_llama_find_draft_model() {
    local target_model_path="$1"
    local target_base="${target_model_path##*/}"
    target_base="${target_base%.gguf}"
    local target_base_lc
    target_base_lc="$(_llama_lower "$target_base")"
    local target_stem
    target_stem="$(_llama_model_strip_quant "$target_base")"
    local target_stem_lc
    target_stem_lc="$(_llama_lower "$target_stem")"
    local dir
    dir=$(dirname "$target_model_path")
    local f b b_no_ext b_lc

    for f in "$dir"/*.gguf; do
        [ -f "$f" ] || continue
        [ "$f" = "$target_model_path" ] && continue
        b="${f##*/}"
        b_no_ext="${b%.gguf}"
        b_lc="$(_llama_lower "$b_no_ext")"
        [[ "$b_lc" != *assistant* ]] && continue
        if [[ "$b_lc" == "$target_stem_lc"* ]]; then
            echo "$f"
            return 0
        fi
        if [[ "$b_lc" == "$target_base_lc"* ]]; then
            echo "$f"
            return 0
        fi
    done

    return 1
}

_llama_binary_supports_mtp() {
    local bin="$1"
    "$bin" --help 2>/dev/null | grep -q -- "draft-mtp"
}

_llama_binary_supports_gemma_assistant() {
    local bin="$1"
    "$bin" --help 2>/dev/null | grep -q -- "gemma4_assistant"
}

_llama_infer_assistant_hf_repo_from_filename() {
    local filename="$1"
    local stem="${filename%.gguf}"
    local repo=""
    case "$stem" in
        gemma-4-26B-A4B-it-*) repo="AtomicChat/gemma-4-26B-A4B-it-assistant-GGUF" ;;
        gemma-4-31B-it-*) repo="AtomicChat/gemma-4-31B-it-assistant-GGUF" ;;
        gemma-4-E4B-it-*) repo="AtomicChat/gemma-4-E4B-it-assistant-GGUF" ;;
    esac
    [ -n "$repo" ] && echo "$repo"
}

_llama_find_local_assistant_dir_for_model() {
    local model_path="$1"
    local filename="${model_path##*/}"
    local stem="${filename%.gguf}"
    local candidate=""
    case "$stem" in
        gemma-4-26B-A4B-it-*) candidate="$LLM_MODELS_DIR/gemma-4-26B-A4B-it-assistant" ;;
        gemma-4-31B-it-*) candidate="$LLM_MODELS_DIR/gemma-4-31B-it-assistant" ;;
        gemma-4-E4B-it-*) candidate="$LLM_MODELS_DIR/gemma-4-E4B-it-assistant" ;;
    esac
    [ -n "$candidate" ] && [ -d "$candidate" ] && echo "$candidate"
}

_llama_resolve_assistant_gguf_for_model() {
    local model_path="$1"
    local draft_model_path=""
    if draft_model_path=$(_llama_find_draft_model "$model_path" 2>/dev/null); then
        echo "$draft_model_path"
        return 0
    fi

    local assistant_repo
    assistant_repo=$(_llama_infer_assistant_hf_repo_from_filename "${model_path##*/}")
    [ -z "$assistant_repo" ] && return 1
    command -v hf >/dev/null 2>&1 || return 1

    local assistant_download_dir="$LLM_MODELS_DIR/.assistant-gguf"
    mkdir -p "$assistant_download_dir"
    local assistant_name="${assistant_repo##*/}.gguf"
    local assistant_gguf="$assistant_download_dir/$assistant_name"

    if [ ! -f "$assistant_gguf" ]; then
        if hf download "$assistant_repo" --include "*.gguf" --local-dir "$assistant_download_dir" >/dev/null 2>&1; then
            local first_gguf
            first_gguf=$(find "$assistant_download_dir" -name "*.gguf" 2>/dev/null | sort | head -1)
            [ -n "$first_gguf" ] && mv -f "$first_gguf" "$assistant_gguf"
        fi
    fi

    [ -f "$assistant_gguf" ] && { echo "$assistant_gguf"; return 0; }
    return 1
}

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

_llama_list() {
    local show_all=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--all) show_all=true; shift ;;
            *) shift ;;
        esac
    done
    python3 - "$LLM_MODELS_DIR" "$_LLAMA_MODEL_INDEX_FILE" "$show_all" <<'PY'
import json
import os
import re
import sys

models_dir, index_file, show_all = sys.argv[1], sys.argv[2], sys.argv[3].lower() == "true"

index = {"models": {}}
if os.path.exists(index_file):
    try:
        with open(index_file, "r") as f:
            index = json.load(f)
    except Exception:
        index = {"models": {}}

def strip_quant(stem: str) -> str:
    return re.sub(r'[-_]((UD|UDT)-)?(IQ[0-9]+_[A-Z0-9]+|Q[0-9]+_[A-Z0-9]+|Q[0-9]+_[A-Z0-9]+_[A-Z0-9]+|Q[0-9]+_[0-9]+|BF16|F16)$', '', stem)

def infer_provider(stem: str) -> str:
    s = stem.lower()
    if s.startswith("gemma-4-"):
        return "google"
    if s.startswith("qwen3.6-"):
        return "unsloth"
    return "local"

def assistant_exists(stem: str) -> bool:
    base = strip_quant(stem)
    for d in (base + "-assistant", base.lower() + "-assistant"):
        if os.path.isdir(os.path.join(models_dir, d)):
            return True
    return False

def infer_tech(stem: str, has_assistant: bool) -> str:
    s = stem.lower()
    if "mlx" in s:
        return "MLX"
    if "mtp" in s:
        return "MTP"
    if has_assistant:
        return "GGUF+assistant"
    return "GGUF"

def quant_suffix(stem: str) -> str:
    m = re.search(r'[-_]((UD|UDT)-)?(IQ[0-9]+_[A-Z0-9]+|Q[0-9]+_[A-Z0-9]+|Q[0-9]+_[A-Z0-9]+_[A-Z0-9]+|Q[0-9]+_[0-9]+|BF16|F16)$', stem)
    return m.group(0).lstrip('-_') if m else ""

def fmt_size(path: str) -> str:
    n = os.path.getsize(path)
    units = [(1<<40, "T"), (1<<30, "G"), (1<<20, "M"), (1<<10, "K")]
    for d, u in units:
        if n >= d:
            v = n / d
            s = f"{v:.1f}" if v < 10 else f"{v:.0f}"
            return f"{s}{u}"
    return f"{n}B"

rows = []
if not os.path.isdir(models_dir):
    print()
    print(f"{'NAME':38} {'SIZE':10} {'PROVIDER':10} {'TECH':14} PATH")
    print(f"{'-'*38} {'-'*10} {'-'*10} {'-'*14} {'-'*28}")
    print()
    raise SystemExit(0)

for entry in sorted(os.listdir(models_dir)):
    if not entry.endswith(".gguf"):
        continue
    if not show_all and entry.startswith("mmproj"):
        continue
    path = os.path.join(models_dir, entry)
    if not os.path.isfile(path):
        continue
    stem = entry[:-5]
    meta = index.get("models", {}).get(entry, {})
    repo = meta.get("repo", "")
    provider = meta.get("provider", "") or (repo.split("/", 1)[0] if "/" in repo else "")
    has_assistant = assistant_exists(stem)
    tech = meta.get("tech", "")
    if not provider:
        provider = infer_provider(stem)
    if not tech:
        tech = infer_tech(stem, has_assistant)
    elif tech == "GGUF" and has_assistant:
        tech = "GGUF+assistant"
    name = repo.split("/", 1)[1] if "/" in repo else stem
    q = quant_suffix(stem)
    if q:
        name = f"{name} [{q}]"
    rows.append((name, fmt_size(path), provider, tech, path))

print()
name_w = max(38, max((len(r[0]) for r in rows), default=0))
size_w = max(10, max((len(r[1]) for r in rows), default=0))
provider_w = max(10, max((len(r[2]) for r in rows), default=0))
tech_w = max(14, max((len(r[3]) for r in rows), default=0))

print(f"{'NAME':<{name_w}} {'SIZE':<{size_w}} {'PROVIDER':<{provider_w}} {'TECH':<{tech_w}} PATH")
print(f"{'-'*name_w} {'-'*size_w} {'-'*provider_w} {'-'*tech_w} {'-'*28}")
for row in rows:
    print(f"{row[0]:<{name_w}} {row[1]:<{size_w}} {row[2]:<{provider_w}} {row[3]:<{tech_w}} {row[4]}")
print()
PY
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
        if ! command -v hf >/dev/null 2>&1; then
            echo "Error: no GGUF files found in $hf_repo and 'hf' CLI is not installed." >&2
            echo "Install with: pip install -U huggingface_hub hf_transfer" >&2
            return 1
        fi
        local mlx_out_dir="$LLM_MODELS_DIR/${hf_repo##*/}"
        echo "▶ No GGUF files found; downloading full repo (MLX or non-GGUF): $hf_repo…"
        hf download "$hf_repo" --local-dir "$mlx_out_dir"
        echo "✓ Saved to $mlx_out_dir"
        return
    fi

    local repo_lc
    repo_lc="$(_llama_lower "$hf_repo")"

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
    local chosen_base="${chosen##*/}"
    local chosen_stem="${chosen_base%.gguf}"
    local filename="${hf_repo##*/}-${chosen_stem}.gguf"
    local out_file="$LLM_MODELS_DIR/$filename"
    echo "▶ Downloading $chosen…"
    if command -v hf >/dev/null 2>&1; then
        hf download "$hf_repo" --include "$chosen" --local-dir "$LLM_MODELS_DIR"
        if [ -f "$LLM_MODELS_DIR/$chosen" ]; then
            mv -f "$LLM_MODELS_DIR/$chosen" "$out_file"
        elif [ -f "$LLM_MODELS_DIR/${chosen##*/}" ]; then
            mv -f "$LLM_MODELS_DIR/${chosen##*/}" "$out_file"
        fi
    else
        curl -L --progress-bar -o "$out_file" "$dl_url"
    fi
    echo "✓ Saved to $out_file"

    if [[ "$filename" != mmproj* ]]; then
        _llama_register_opencode "$filename"
        _llama_model_meta_set "$filename" "$hf_repo" "$(_llama_repo_tech "$hf_repo")"
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
                if command -v hf >/dev/null 2>&1; then
                    hf download "$hf_repo" --include "$mmproj_remote" --local-dir "$LLM_MODELS_DIR"
                    [ -f "$LLM_MODELS_DIR/$mmproj_remote" ] && mv -f "$LLM_MODELS_DIR/$mmproj_remote" "$mmproj_out"
                else
                    curl -L --progress-bar -o "$mmproj_out" "https://huggingface.co/${hf_repo}/resolve/main/${mmproj_remote}"
                fi
                echo "✓ Saved to $mmproj_out"
            fi
        fi
    fi
}

_llama_rm() {
    [ $# -eq 0 ] && { echo "Usage: llama remove|rm <model> [model2 ...]"; return 1; }

    local model_paths=()
    local mmproj_paths=()
    local query model_path mmproj_path p exists

    while [[ $# -gt 0 ]]; do
        query="$1"
        shift
        if ! model_path=$(_llama_find_model "$query" 2>/dev/null); then
            echo "  ! Skipping: model '$query' not found"
            continue
        fi

        exists=0
        for p in "${model_paths[@]}"; do
            [ "$p" = "$model_path" ] && { exists=1; break; }
        done
        [ "$exists" = "0" ] && model_paths+=("$model_path")

        mmproj_path=$(_llama_find_mmproj "$model_path" 2>/dev/null || echo "")
        if [ -n "$mmproj_path" ]; then
            exists=0
            for p in "${mmproj_paths[@]}"; do
                [ "$p" = "$mmproj_path" ] && { exists=1; break; }
            done
            [ "$exists" = "0" ] && mmproj_paths+=("$mmproj_path")
        fi
    done

    [ ${#model_paths[@]} -eq 0 ] && { echo "No matching models found."; return 1; }

    for p in "${model_paths[@]}"; do
        echo "🗑  Target: ${p##*/}"
    done
    for p in "${mmproj_paths[@]}"; do
        [ -f "$p" ] && echo "🗑  Vision: ${p##*/}"
    done

    printf "Delete these files? [y/N] "
    read -r confirm
    if [[ "${confirm:-n}" =~ ^[Yy]$ ]]; then
        for p in "${model_paths[@]}"; do
        if [ -f "$p" ]; then
                _llama_model_meta_remove "${p##*/}"
                rm -v "$p" 2>&1 | sed 's|^.*|  ✓ Removed |'
            fi
        done
        for p in "${mmproj_paths[@]}"; do
            [ -f "$p" ] && rm -v "$p" 2>&1 | sed 's|^.*|  ✓ Removed |'
        done
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
