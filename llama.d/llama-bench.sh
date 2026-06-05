#!/usr/bin/env bash
# llama-bench.sh — Benchmark and speed tests

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
