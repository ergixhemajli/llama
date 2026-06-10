#!/usr/bin/env bash
# llama-helpers.sh — Shared helper functions for llama-aliases

_llama_lower() {
    printf '%s' "$*" | tr '[:upper:]' '[:lower:]'
}

_llama_cpu_threads() {
    if [ -n "${LLM_DEFAULT_THREADS:-}" ]; then
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

_llama_resolve_cache_type_k() {
    if [ -n "${LLM_DEFAULT_CACHE_TYPE_K:-}" ]; then
        echo "$LLM_DEFAULT_CACHE_TYPE_K"
    else
        echo "q8_0"
    fi
}

_llama_resolve_cache_type_v() {
    if [ -n "${LLM_DEFAULT_CACHE_TYPE_V:-}" ]; then
        echo "$LLM_DEFAULT_CACHE_TYPE_V"
    else
        echo "q8_0"
    fi
}

_llama_server_running() {
    local host="${LLM_SERVER_HOST:-127.0.0.1}"
    local port="${LLM_SERVER_PORT:-11434}"
    curl -s --max-time 2 "http://${host}:${port}/v1/models" >/dev/null 2>&1
}

_llama_binary_supports_mtp() {
    local bin="$1"
    "$bin" --help 2>/dev/null | grep -q -- "draft-mtp"
}

_llama_binary_supports_gemma_assistant() {
    local bin="$1"
    "$bin" --help 2>/dev/null | grep -q -- "draft-mtp"
}

_llama_supports_reasoning() {
    llama-cli --help 2>/dev/null | grep -q -- "--reasoning"
}
