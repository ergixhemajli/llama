#!/usr/bin/env bash

if [[ -n "$BASH_VERSION" ]]; then
    _llama_bash_complete() {
        local cur="${COMP_WORDS[COMP_CWORD]}"
        local prev="${COMP_WORDS[COMP_CWORD-1]}"
        local subcmds="run serve list pull rm remove stop ps logs doctor config bench ask pipe help"

        if [[ ${#COMP_WORDS[@]} -eq 2 ]]; then
            COMPREPLY=( $(compgen -W "$subcmds" -- "$cur") )
            return
        fi

        if [[ ${#COMP_WORDS[@]} -eq 3 ]]; then
            case "$prev" in
                run|serve|rm|remove|doctor|bench|ask|pipe)
                    if [[ -d "$LLM_MODELS_DIR" ]]; then
                        local models=()
                        while IFS= read -r -d '' f; do
                            local bname="${f##*/}"
                            models+=("${bname%.gguf}")
                        done < <(find "$LLM_MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null | sort -z)
                        COMPREPLY=( $(compgen -W "${models[*]}" -- "$cur") )
                    fi
                    ;;
            esac
        fi
    }
    complete -F _llama_bash_complete llama

    _llama_ask_complete() {
        local cur="${COMP_WORDS[COMP_CWORD]}"
        if [[ ${#COMP_WORDS[@]} -eq 2 && -d "$LLM_MODELS_DIR" ]]; then
            local models=()
            while IFS= read -r -d '' f; do
                local bname="${f##*/}"
                models+=("${bname%.gguf}")
            done < <(find "$LLM_MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null | sort -z)
            COMPREPLY=( $(compgen -W "${models[*]}" -- "$cur") )
        fi
    }
    complete -F _llama_ask_complete llama-ask

    _llama_pipe_complete() {
        local cur="${COMP_WORDS[COMP_CWORD]}"
        if [[ ${#COMP_WORDS[@]} -eq 2 && -d "$LLM_MODELS_DIR" ]]; then
            local models=()
            while IFS= read -r -d '' f; do
                local bname="${f##*/}"
                models+=("${bname%.gguf}")
            done < <(find "$LLM_MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null | sort -z)
            COMPREPLY=( $(compgen -W "${models[*]}" -- "$cur") )
        elif [[ ${#COMP_WORDS[@]} -ge 4 ]]; then
            COMPREPLY=( $(compgen -f -- "$cur") )
        fi
    }
    complete -F _llama_pipe_complete llama-pipe
fi

if [[ -n "$ZSH_VERSION" && -o interactive ]]; then
    _llama_complete() {
        local state
        local -a subcommands models
        subcommands=(
            'run:Interactive chat with a model'
            'serve:Start OpenAI-compatible API server'
            'list:List downloaded models'
            'pull:Download a model from Hugging Face'
            'remove:Remove a downloaded model and its mmproj'
            'ps:Show running server info'
            'stop:Stop the running server'
            'logs:Show server logs'
            'doctor:Check runtime health'
            'config:Set runtime toggles'
            'bench:Benchmark inference speed'
            'ask:One-shot question to a model'
            'pipe:Pipe stdin or file into a model with instruction'
            'help:Show help'
        )
        _arguments -C '1: :->subcmd' '2: :->model' '*: :->args' && return
        case $state in
            subcmd) _describe 'subcommand' subcommands ;;
            model)
                case $words[2] in
                    run|serve|remove|doctor|bench|ask|pipe)
                        models=($(find "$LLM_MODELS_DIR" -name "*.gguf" 2>/dev/null | xargs -I{} basename {} .gguf | sort))
                        _describe 'model' models ;;
                esac ;;
        esac
    }
    compdef _llama_complete llama

    _llama_cmd_complete() {
        local -a models
        models=($(find "$LLM_MODELS_DIR" -name "*.gguf" 2>/dev/null | xargs -I{} basename {} .gguf | sort))
        _arguments '1:model:($models)'
    }
    compdef _llama_cmd_complete llama-ask

    _llama_pipe_complete() {
        local -a models
        models=($(find "$LLM_MODELS_DIR" -name "*.gguf" 2>/dev/null | xargs -I{} basename {} .gguf | sort))
        _arguments '1:model:($models)' '2:instruction:' '3:file:_files'
    }
    compdef _llama_pipe_complete llama-pipe
fi
