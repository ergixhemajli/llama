#!/usr/bin/env bash
# llama-aliases.sh — Main entry point / subcommand router
# Sources modular files in dependency order, replacing llama-core.sh

if [ -z "$_LLAMA_LOADED" ]; then
    _LLAMA_LOADED=1
    local_source_file=""
    if [ -n "${BASH_SOURCE[0]:-}" ]; then
        local_source_file="${BASH_SOURCE[0]}"
    elif [ -n "${ZSH_VERSION:-}" ]; then
        local_source_file="${(%):-%N}"
    else
        local_source_file="$0"
    fi
    _LLAMA_DIR="${local_source_file%/*}"
    if [ "$_LLAMA_DIR" = "." ]; then
        _LLAMA_DIR="$(cd "$(dirname "$0")" && pwd)"
    fi

    # Source order: env -> helpers -> models -> opencode -> pull/list/rm -> server -> extras -> completions
    source "$_LLAMA_DIR/llama.d/llama-env.sh"
    source "$_LLAMA_DIR/llama.d/llama-helpers.sh"
    source "$_LLAMA_DIR/llama.d/llama-models.sh"
    source "$_LLAMA_DIR/llama.d/llama-opencode.sh"
    source "$_LLAMA_DIR/llama.d/llama-pull.sh"
    source "$_LLAMA_DIR/llama.d/llama-list.sh"
    source "$_LLAMA_DIR/llama.d/llama-rm.sh"
    source "$_LLAMA_DIR/llama.d/llama-server.sh"
    source "$_LLAMA_DIR/llama.d/llama-config.sh"
    source "$_LLAMA_DIR/llama.d/llama-bench.sh"
    source "$_LLAMA_DIR/llama.d/llama-extras.sh"
    source "$_LLAMA_DIR/llama.d/llama-completions.sh"
fi

# Subcommand router
llama() {
    local cmd="${1:-help}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
        serve)        _llama_serve "$@" ;;
        run)          _llama_run "$@" ;;
        stop)         _llama_stop ;;
        ps)           _llama_ps ;;
        pull|download) _llama_pull "$@" ;;
        list|ls)      _llama_list "$@" ;;
        rm|remove)    _llama_rm "$@" ;;
        config)       _llama_config "$@" ;;
        bench)        _llama_bench "$@" ;;
        speed)        _llama_speed "$@" ;;
        pipe)         _llama_pipe "$@" ;;
        pipe-mlx)
            echo "'llama pipe-mlx' is not available in this build."
            echo "Use: llama run --mlx <huggingface-repo>"
            return 1
            ;;
        opencode)     _llama_register_opencode "$@" ;;
        logs)         _llama_logs "$@" ;;
        doctor)       _llama_doctor "$@" ;;
        completions)
            echo "Shell completions are loaded when llama-aliases.sh is sourced."
            echo "Run 'complete -p llama' (bash) or 'which _llama_complete' (zsh) to verify."
            ;;
        update)
            echo "'llama update' is not implemented in this modular build."
            return 1
            ;;
        --help|-h|help)
            if declare -F _llama_help >/dev/null 2>&1; then
                _llama_help
            else
                echo "Usage: llama <subcommand> [options]"
            fi
            ;;
        *)
            echo "Unknown command: $cmd" >&2
            echo "Run 'llama help' for usage." >&2
            return 1
            ;;
    esac
}
