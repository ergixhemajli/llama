#!/usr/bin/env bash
# llama-aliases.sh — Ollama-style aliases for llama.cpp

_llama_source_path="$0"
if [ -n "$BASH_VERSION" ]; then
    _llama_source_path="${BASH_SOURCE[0]}"
elif [ -n "$ZSH_VERSION" ]; then
    _llama_source_path="${(%):-%N}"
fi
_llama_dir="$(cd "$(dirname "$_llama_source_path")" && pwd)"

# shellcheck source=llama.d/llama-core.sh
source "$_llama_dir/llama.d/llama-core.sh"
# shellcheck source=.llama.d/llama-extras.sh
source "$_llama_dir/llama.d/llama-extras.sh"

llama() {
    local subcmd="$1"; shift
    case "$subcmd" in
        run)        _llama_run "$@" ;;
        serve)      _llama_serve "$@" ;;
        list)       _llama_list "$@" ;;
        pull)       _llama_pull "$@" ;;
        rm|remove)  _llama_rm "$@" ;;
        stop)       _llama_stop ;;
        ps)         _llama_ps ;;
        logs)       _llama_logs "$@" ;;
        doctor)     _llama_doctor "$@" ;;
        config)     _llama_config "$@" ;;
        bench)      _llama_bench "$@" ;;
        ask)        _llama_ask "$@" ;;
        pipe)       _llama_pipe "$@" ;;
        help|"")    _llama_help ;;
        *)
            echo "Unknown subcommand: $subcmd"
            echo "Run 'llama help' for usage."
            return 1
            ;;
    esac
}

# shellcheck source=.llama.d/llama-completions.sh
source "$_llama_dir/llama.d/llama-completions.sh"

echo "🦙 \033[2mllama.cpp\033[0m"
