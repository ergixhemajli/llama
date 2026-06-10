#!/usr/bin/env bash
# llama-convert.sh — Convert HuggingFace models to GGUF (including MTP assistants)

_convert_script_dir() {
    echo "$_LLAMA_DIR/convert"
}

_convert_python() {
    local py_path
    py_path=$(command -v python3 2>/dev/null) || { echo "Error: python3 not found" >&2; return 1; }
    echo "$py_path"
}

_llama_convert() {
    local convert_dir script
    convert_dir=$(_convert_script_dir)
    script="$convert_dir/convert_hf_to_gguf.py"
    [ ! -f "$script" ] && { echo "Error: conversion script not found. Run 'llama update-convert'." >&2; return 1; }

    local model_path="${1:?Usage: llama convert <model-dir-or-hf-repo> [options]}"
    shift

    # Resolve bare local directory names from model store
    if [ ! -e "$model_path" ] && [ -d "$LLM_MODELS_DIR/$model_path" ]; then
        model_path="$LLM_MODELS_DIR/$model_path"
    fi

    # Optional override flags for auto-mode
    local force_mode="auto" # auto|full|mtp
    local passthrough=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full) force_mode="full"; shift ;;
            --mtp)  force_mode="mtp"; shift ;;
            *)      passthrough+=("$1"); shift ;;
        esac
    done

    # Auto-detect assistant/draft models and route to MTP conversion path.
    local looks_like_assistant=0
    local lower
    lower=$(printf '%s' "$model_path" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower" == *assistant* ]] || [[ "$lower" == *"-mtp"* ]]; then
        looks_like_assistant=1
    elif [ -d "$model_path" ] && [ -f "$model_path/config.json" ]; then
        if grep -qiE '"model_type"[[:space:]]*:[[:space:]]*"[^"]*assistant|"architectures"[[:space:]]*:[[:space:]]*\[[^]]*Assistant' "$model_path/config.json"; then
            looks_like_assistant=1
        fi
    fi

    # Gemma assistant currently converts better as a regular full GGUF export
    # (without --mtp), while upstream --mtp path is still limited.
    if [ "$force_mode" = "mtp" ]; then
        echo "[INFO] convert: forcing MTP conversion mode (--mtp)"
        _llama_convert_mtp "$model_path" "${passthrough[@]}"
        return $?
    fi

    if [ "$force_mode" = "auto" ] && [ "$looks_like_assistant" -eq 1 ]; then
        if [[ "$lower" == *"gemma"* && "$lower" == *"assistant"* ]]; then
            echo "[INFO] convert: detected Gemma assistant -> using full conversion mode (no --mtp)"
        else
            echo "[INFO] convert: detected assistant/MTP source -> using MTP conversion mode"
            _llama_convert_mtp "$model_path" "${passthrough[@]}"
            return $?
        fi
    fi

    local py_path
    py_path=$(_convert_python) || return 1
    $py_path "$script" "${passthrough[@]}" -- "$model_path"
}

_llama_assistant_repo_from_input() {
    local input="$1"
    local lc
    lc=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')
    case "$lc" in
        *gemma-4-26b-a4b-it-assistant*) echo "AtomicChat/gemma-4-26B-A4B-it-assistant-GGUF" ;;
        *gemma-4-31b-it-assistant*)     echo "AtomicChat/gemma-4-31B-it-assistant-GGUF" ;;
        *gemma-4-e4b-it-assistant*)     echo "AtomicChat/gemma-4-E4B-it-assistant-GGUF" ;;
        *) return 1 ;;
    esac
}

_llama_download_preconverted_assistant_gguf() {
    local input="$1"
    command -v hf >/dev/null 2>&1 || { echo "hf CLI not installed; cannot auto-download assistant GGUF." >&2; return 1; }

    local repo
    repo=$(_llama_assistant_repo_from_input "$input") || return 1

    local out_dir="$LLM_MODELS_DIR/.assistant-gguf"
    mkdir -p "$out_dir"
    echo "▶ Fallback: downloading pre-converted assistant GGUF from $repo ..." >&2
    if ! hf download "$repo" --include "*.gguf" --local-dir "$out_dir" >/dev/null 2>&1; then
        echo "Failed to download pre-converted assistant GGUF from $repo" >&2
        return 1
    fi

    echo "✓ Saved assistant GGUF(s) in $out_dir" >&2
    return 0
}

_llama_convert_mtp() {
    local convert_dir script
    convert_dir=$(_convert_script_dir)
    script="$convert_dir/convert_hf_to_gguf.py"
    [ ! -f "$script" ] && { echo "Error: conversion script not found. Run 'llama update-convert'." >&2; return 1; }
    local model_path="${1:?Usage: llama convert-mtp <model-dir-or-hf-repo> [options]}"
    shift

    if [ ! -e "$model_path" ] && [ -d "$LLM_MODELS_DIR/$model_path" ]; then
        model_path="$LLM_MODELS_DIR/$model_path"
    fi
    local py_path
    py_path=$(_convert_python) || return 1
    local outfile="" outtype="auto" extra_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --outfile|-o) outfile="$2"; shift 2 ;;
            --outtype|-q) outtype="$2"; shift 2 ;;
            --dry-run) extra_args+=(--dry-run); shift ;;
            *) extra_args+=("$1"); shift ;;
        esac
    done
    local args=(--mtp "--outtype=$outtype")
    [ -n "$outfile" ] && args+=(--outfile "$outfile")
    local output
    output=$($py_path "$script" "${args[@]}" "${extra_args[@]}" -- "$model_path" 2>&1)
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "$output" >&2
        if echo "$output" | grep -qE "only supported for Qwen|only supported for Step3|gemma4_assistant"; then
            echo "" >&2
            echo "⚠ convert_hf_to_gguf.py does not yet support converting this model's MTP head to GGUF." >&2

            echo "" >&2
            echo "Options for MTP assistant GGUF:" >&2
            echo "  1. Download pre-converted GGUF: hf download AtomicChat/<repo>-assistant-GGUF --include '*.gguf'" >&2
            echo "  2. Wait for llama.cpp update adding gemma4_assistant conversion support" >&2
            echo "  3. Auto-detect: serve with 'llama serve <model>' if your binary supports gemma4_assistant" >&2
        fi
        return 1
    fi
}

_llama_convert_mtp_from_assistant_dir() {
    local convert_dir script
    convert_dir=$(_convert_script_dir)
    script="$convert_dir/convert_hf_to_gguf.py"
    [ ! -f "$script" ] && { echo "Error: conversion script not found. Run 'llama update-convert'." >&2; return 1; }
    local assistant_path="${1:?Usage: llama convert-assistant <assistant-dir-or-hf-repo> [base-model-alias] [options]}"
    shift

    if [ ! -e "$assistant_path" ] && [ -d "$LLM_MODELS_DIR/$assistant_path" ]; then
        assistant_path="$LLM_MODELS_DIR/$assistant_path"
    fi
    local base_alias="" outtype="auto" outfile="" extra_args=()
    [[ $# -gt 0 ]] && [[ ! "$1" =~ ^- ]] && { base_alias="$1"; shift; }
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --outtype|-q) outtype="$2"; shift 2 ;;
            --outfile|-o) outfile="$2"; shift 2 ;;
            --dry-run) extra_args+=(--dry-run); shift ;;
            *) extra_args+=("$1"); shift ;;
        esac
    done
    if [ -z "$outfile" ] && [ -n "$base_alias" ]; then
        local model_path
        model_path=$(_llama_find_model "$base_alias" 2>/dev/null)
        if [ -n "$model_path" ]; then
            local base_name="${model_path##*/}"
            base_name="${base_name%.gguf}"
            outfile="$LLM_MODELS_DIR/mtp-${base_name}.auto.gguf"
        fi
    fi
    [ -z "$outfile" ] && outfile="$LLM_MODELS_DIR/mtp-assistant.auto.gguf"
    local py_path
    py_path=$(_convert_python) || return 1
    local args=(--mtp "--outtype=$outtype" "--outfile=$outfile")
    local output
    output=$($py_path "$script" "${args[@]}" "${extra_args[@]}" -- "$assistant_path" 2>&1)
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "$output" >&2
        if echo "$output" | grep -qE "only supported for Qwen|only supported for Step3|gemma4_assistant"; then
            echo "" >&2
            echo "⚠ convert_hf_to_gguf.py does not yet support converting this model's MTP head to GGUF." >&2

            echo "  Download pre-converted (manual): hf download AtomicChat/<repo>-assistant-GGUF --include '*.gguf'" >&2
            echo "  Or auto-detect: serve with 'llama serve <model>' if your binary supports gemma4_assistant" >&2
        fi
        return 1
    fi
}

_llama_update_convert() {
    local convert_dir tmp_dir
    convert_dir=$(_convert_script_dir)
    echo "Updating conversion tools from llama.cpp..."
    tmp_dir="/tmp/llama.cpp-convert-update-$$"
    [ -d "$tmp_dir" ] && rm -rf "$tmp_dir"
    git clone --depth=1 https://github.com/ggml-org/llama.cpp "$tmp_dir" 2>&1 | tail -3
    if [ ! -d "$tmp_dir" ] || [ ! -f "$tmp_dir/convert_hf_to_gguf.py" ]; then
        echo "Error: failed to fetch update" >&2; rm -rf "$tmp_dir"; return 1
    fi
    mkdir -p "$convert_dir/conversion" "$convert_dir/gguf-py"
    cp "$tmp_dir/convert_hf_to_gguf.py" "$convert_dir/"
    cp "$tmp_dir/convert_llama_ggml_to_gguf.py" "$convert_dir/" 2>/dev/null
    cp "$tmp_dir/convert_lora_to_gguf.py" "$convert_dir/" 2>/dev/null
    cp "$tmp_dir/convert_hf_to_gguf_update.py" "$convert_dir/" 2>/dev/null
    cp "$tmp_dir/requirements.txt" "$convert_dir/" 2>/dev/null
    [ -d "$tmp_dir/conversion" ] && cp -r "$tmp_dir/conversion/." "$convert_dir/conversion/"
    [ -d "$tmp_dir/gguf-py" ] && cp -r "$tmp_dir/gguf-py/." "$convert_dir/gguf-py/"
    rm -rf "$tmp_dir"
    echo "Conversion tools updated."
    echo ""
    echo "Python dependencies:"
    echo "  pip3 install torch --index-url https://download.pytorch.org/whl/cpu"
    echo "  pip3 install transformers gguf"
}

_llama_check_convert_prereqs() {
    local convert_dir issues py_path
    convert_dir=$(_convert_script_dir)
    [ ! -f "$convert_dir/convert_hf_to_gguf.py" ] && { echo "Conversion tools not installed. Run 'llama update-convert'." >&2; return 1; }
    issues=()
    py_path=$(_convert_python)
    if [ -z "$py_path" ]; then
        issues+=("python3 not found")
    else
        $py_path -c "import torch" 2>/dev/null || issues+=("torch not installed")
        $py_path -c "import transformers" 2>/dev/null || issues+=("transformers not installed")
        $py_path -c "import gguf" 2>/dev/null || issues+=("gguf package not installed")
        $py_path -c "import protobuf" 2>/dev/null || $py_path -c "import google.protobuf" 2>/dev/null || issues+=("protobuf not installed")
        $py_path -c "import sentencepiece" 2>/dev/null || issues+=("sentencepiece not installed (often needed for tokenizer export)")
    fi
    if [ ${#issues[@]} -gt 0 ]; then
        echo "Conversion tools installed but missing dependencies:" >&2
        for issue in "${issues[@]}"; do echo "  ⚠ $issue" >&2; done
        echo "" >&2
        echo "Install with:" >&2
        echo "  pip3 install torch --index-url https://download.pytorch.org/whl/cpu" >&2
        echo "  pip3 install transformers gguf protobuf sentencepiece" >&2
        return 1
    fi
    return 0
}
