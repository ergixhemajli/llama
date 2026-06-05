#!/usr/bin/env bash
# llama-helpers.sh — Utility functions

_llama_bool_is_true() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

_llama_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

_llama_spinner_char() {
    case $(( $1 % 4 )) in
        0) printf '|' ;;
        1) printf '/' ;;
        2) printf '-' ;;
        3) printf '\\' ;;
    esac
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

_llama_server_running() {
    curl -sf "http://${LLM_SERVER_HOST}:${LLM_SERVER_PORT}/health" > /dev/null 2>&1
}

_llama_binary_supports_mtp() {
    local bin="$1"
    "$bin" --help 2>/dev/null | grep -q -- "draft-mtp"
}

_llama_binary_supports_gemma_assistant() {
    local bin="$1"
    "$bin" --help 2>/dev/null | grep -q -- "gemma4_assistant"
}

_llama_supports_reasoning() {
    llama-cli --help 2>/dev/null | grep -q -- "--reasoning"
}
