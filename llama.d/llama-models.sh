#!/usr/bin/env bash
# llama-models.sh — Model metadata, discovery, and resolution

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

_llama_model_strip_quant() {
    echo "$1" | sed -E 's/[-_]((UD|UDT)-)?(IQ[0-9]+_[A-Z0-9]+|Q[0-9]+_[A-Z0-9]+|Q[0-9]+_[A-Z0-9]+_[A-Z0-9]+|Q[0-9]+_[0-9]+|BF16|F16)$//'
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

_llama_model_supports_mtp() {
    local model_ref="$1"
    [ "$(_llama_model_tech_for_file "$model_ref")" = "MTP" ]
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
