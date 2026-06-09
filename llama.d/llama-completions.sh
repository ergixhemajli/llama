#!/usr/bin/env bash

if [[ -n "$BASH_VERSION" ]]; then
    _llama_bash_complete() {
        local cur="${COMP_WORDS[COMP_CWORD]}"
        local prev="${COMP_WORDS[COMP_CWORD-1]}"
        local subcmds="run serve list pull rm remove stop ps logs doctor config bench speed pipe opencode pi completions help"
        if [[ ${#COMP_WORDS[@]} -eq 2 ]]; then
            COMPREPLY=( $(compgen -W "$subcmds" -- "$cur") )
            return
        fi

        case "$prev" in
            config)
                COMPREPLY=( $(compgen -W "show ctx LLM_DEFAULT_CTX threads cache pipe-n no-thinking save load" -- "$cur") )
                return
                ;;
            no-thinking)
                COMPREPLY=( $(compgen -W "on off" -- "$cur") )
                return
                ;;
        esac

        if [[ ${#COMP_WORDS[@]} -ge 3 ]]; then
            case "${COMP_WORDS[1]}" in
                run|serve|rm|remove|doctor|bench|speed|pipe)
                    if [[ -d "$LLM_MODELS_DIR" ]]; then
                        local models=()
                        while IFS= read -r -d '' f; do
                            local bname="${f##*/}"
                            [[ "$bname" == mmproj* ]] && continue
                            models+=("${bname%.gguf}")
                        done < <(find "$LLM_MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null | sort -z)
                        COMPREPLY=( $(compgen -W "${models[*]}" -- "$cur") )
                    fi
                    ;;
            esac
        fi
    }
    complete -F _llama_bash_complete llama

    _llama_pipe_complete() {
        local cur="${COMP_WORDS[COMP_CWORD]}"
        if [[ ${#COMP_WORDS[@]} -eq 2 && -d "$LLM_MODELS_DIR" ]]; then
            local models=()
            while IFS= read -r -d '' f; do
                local bname="${f##*/}"
                [[ "$bname" == mmproj* ]] && continue
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
        local -a config_keys
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
            'speed:Measure generation speed with runtime path'
            'pipe:Pipe stdin or file into a model with instruction'
            'opencode:Register model in OpenCode + Pi configs'
            'pi:Register model in OpenCode + Pi configs'
            'completions:Show completion setup status'
            'help:Show help'
        )
        config_keys=(
            'show:Show current runtime config'
            'ctx:Set context size'
            'LLM_DEFAULT_CTX:Set context size'
            'threads:Set thread count'
            'cache:Set KV cache type'
            'pipe-n:Set pipe output tokens'
            'no-thinking:Set default no-thinking toggle'
            'save:Save runtime config'
            'load:Load runtime config'
        )
        _arguments -C '1: :->subcmd' '2: :->model' '*: :->args' && return
        case $state in
            subcmd) _describe 'subcommand' subcommands ;;
            model)
                case $words[2] in
                    config)
                        _describe 'config key' config_keys ;;
                    run|serve|remove|doctor|bench|speed|pipe)
                        models=()
                        while IFS= read -r -d '' f; do
                            local bname="${f##*/}"
                            [[ "$bname" == mmproj* ]] && continue
                            models+=("${bname%.gguf}")
                        done < <(find "$LLM_MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null | sort -z)
                        _describe 'model' models ;;
                esac ;;
        esac
    }
    compdef _llama_complete llama

    _llama_cmd_complete() {
        local -a models
        models=()
        while IFS= read -r -d '' f; do
            local bname="${f##*/}"
            [[ "$bname" == mmproj* ]] && continue
            models+=("${bname%.gguf}")
        done < <(find "$LLM_MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null | sort -z)
        _arguments '1:model:($models)'
    }
    compdef _llama_cmd_complete llama-ask

    _llama_speed_complete() {
        local -a models
        models=()
        while IFS= read -r -d '' f; do
            local bname="${f##*/}"
            [[ "$bname" == mmproj* ]] && continue
            models+=("${bname%.gguf}")
        done < <(find "$LLM_MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null | sort -z)
        _arguments '1:model:($models)' '--tokens[tokens per run]:tokens' '--runs[number of runs]:runs'
    }
    compdef _llama_speed_complete llama-speed

    _llama_pipe_complete() {
        local -a models
        models=()
        while IFS= read -r -d '' f; do
            local bname="${f##*/}"
            [[ "$bname" == mmproj* ]] && continue
            models+=("${bname%.gguf}")
        done < <(find "$LLM_MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null | sort -z)
        _arguments '1:model:($models)' '2:instruction:' '3:file:_files'
    }
    compdef _llama_pipe_complete llama-pipe
fi
