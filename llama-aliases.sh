#!/usr/bin/env bash
# llama-aliases.sh — Ollama-style aliases for llama.cpp

LLM_MODELS_DIR="${LLM_MODELS_DIR:-$HOME/.llama/llama-models}"
LLM_DEFAULT_CTX="${LLM_DEFAULT_CTX:-32768}"
LLM_DEFAULT_GPU_LAYERS="${LLM_DEFAULT_GPU_LAYERS:-99}"   # 0 = CPU only, 99 = all to GPU
LLM_SERVER_HOST="${LLM_SERVER_HOST:-127.0.0.1}"
LLM_SERVER_PORT="${LLM_SERVER_PORT:-11434}"
LLM_HF_DEFAULT_USER="${LLM_HF_DEFAULT_USER:-unsloth}"

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

    # Exact match
    local candidate="$LLM_MODELS_DIR/mmproj-F16-${base}.gguf"
    [ -f "$candidate" ] && { echo "$candidate"; return 0; }

    # Strip quant suffix and try again
    local stripped
    stripped=$(echo "$base" | sed -E 's/[-_](UD-)?Q[0-9]+_[A-Z0-9]+(_[A-Z0-9]+)*$//')
    candidate="$LLM_MODELS_DIR/mmproj-F16-${stripped}.gguf"
    [ -f "$candidate" ] && { echo "$candidate"; return 0; }

    # Fuzzy: mmproj starts with stripped base
    local fuzzy
    fuzzy=$(find "$LLM_MODELS_DIR" -iname "mmproj-F16-${stripped}*.gguf" 2>/dev/null | head -1)
    [ -n "$fuzzy" ] && { echo "$fuzzy"; return 0; }

    return 1
}

_llama_server_running() {
    curl -sf "http://${LLM_SERVER_HOST}:${LLM_SERVER_PORT}/health" > /dev/null 2>&1
}

llama() {
    local subcmd="$1"; shift
    case "$subcmd" in
        run)        _llama_run "$@" ;;
        serve)      _llama_serve "$@" ;;
        list)       _llama_list "$@" ;;
        pull)       _llama_pull "$@" ;;
        rm|remove)  _llama_rm "$@" ;;
        show)       _llama_show "$@" ;;
        stop)       _llama_stop ;;
        ps)         _llama_ps ;;
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

_llama_run() {
    local model_query="$1"; shift
    local model_path
    model_path=$(_llama_find_model "$model_query") || return 1
    local mmproj_path=""
    if mmproj_path=$(_llama_find_mmproj "$model_path"); then
        echo "  Vision projector: ${mmproj_path##*/}"
    fi
    echo "▶ Running: ${model_path##*/}"
    local args=(
        --model "$model_path"
        --ctx-size "$LLM_DEFAULT_CTX"
        --n-gpu-layers "$LLM_DEFAULT_GPU_LAYERS"
        --threads "$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
        -cnv
    )
    [ -n "$mmproj_path" ] && args+=(--mmproj "$mmproj_path")
    llama-cli "${args[@]}" "$@"
}

_llama_serve() {
    local model_query="$1"; shift
    local model_path
    model_path=$(_llama_find_model "$model_query") || return 1
    local mmproj_path
    mmproj_path=$(_llama_find_mmproj "$model_path") || {
        local _base; _base=$(basename "$model_path" .gguf)
        local _stripped; _stripped=$(echo "$_base" | sed -E 's/[-_](UD-)?Q[0-9]+_[A-Z0-9]+(_[A-Z0-9]+)*$//')
        echo "  WARNING: No mmproj found for $model_path"
        echo "  Expected: mmproj-F16-${_stripped}.gguf"
        mmproj_path=""
    }
    [ -n "$mmproj_path" ] && echo "  Vision projector: ${mmproj_path##*/}"
    echo "▶ Serving: ${model_path##*/}"
    local args=(
        --model "$model_path"
        --ctx-size "$LLM_DEFAULT_CTX"
        --n-gpu-layers "$LLM_DEFAULT_GPU_LAYERS"
        --threads "$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
        --host "$LLM_SERVER_HOST"
        --port "$LLM_SERVER_PORT"
    )
    [ -n "$mmproj_path" ] && args+=(--mmproj "$mmproj_path")
    llama-server "${args[@]}" "$@"
}

_llama_list() {
    local show_all=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--all) show_all=true; shift ;;
            *) shift ;;
        esac
    done
    echo ""
    printf "%-50s %-10s %s\n" "NAME" "SIZE" "PATH"
    printf "%-50s %-10s %s\n" "────────────────────────────────────────────────" "──────────" "────────────────────────────"
    find "$LLM_MODELS_DIR" -name "*.gguf" 2>/dev/null | sort | while IFS= read -r f; do
        local bname="${f##*/}"
        [[ "$show_all" == false && "$bname" == mmproj* ]] && continue
        printf "%-50s %-10s %s\n" "${bname%.gguf}" "$(du -sh "$f" 2>/dev/null | awk '{print $1}')" "$f"
    done
    echo ""
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
        echo "Error: no GGUF files found in $hf_repo"
        return 1
    fi

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
    local filename="${chosen##*/}"
    local out_file="$LLM_MODELS_DIR/$filename"
    echo "▶ Downloading $chosen…"
    curl -L --progress-bar -o "$out_file" "$dl_url"
    echo "✓ Saved to $out_file"

    if [[ "$filename" != mmproj* ]]; then
        _llama_register_opencode "$filename"
    fi

		if [[ "$filename" != mmproj* ]]; then
			local mmproj_remote="mmproj-F16.gguf"
			local http_status
			http_status=$(curl -sf -o /dev/null -w "%{http_code}" -L --max-time 5 "https://huggingface.co/${hf_repo}/resolve/main/${mmproj_remote}" 2>/dev/null)
			if [ "$http_status" = "200" ]; then
				local model_base="${filename%.gguf}"
				local stripped_base
				stripped_base=$(echo "$model_base" | sed -E 's/[-_](UD-)?Q[0-9]+_[A-Z0-9]+(_[A-Z0-9]+)*$//')
				local mmproj_out="$LLM_MODELS_DIR/mmproj-F16-${stripped_base}.gguf"
				echo ""
				printf "Vision projector (mmproj-F16) found — download it? [Y/n] "
				read -r mmproj_confirm
				if [[ "${mmproj_confirm:-Y}" =~ ^[Yy]$ ]]; then
					echo "▶ Downloading mmproj-F16 → ${mmproj_out##*/}…"
					curl -L --progress-bar -o "$mmproj_out" "https://huggingface.co/${hf_repo}/resolve/main/${mmproj_remote}"
					echo "✓ Saved to $mmproj_out"
				fi
			fi
    fi
}

_llama_rm() {
    local model_query="$1"
    [ -z "$model_query" ] && { echo "Usage: llama remove|rm <model>"; return 1; }
    local model_path
    model_path=$(_llama_find_model "$model_query") || return 1

    local model_base="${model_path##*/}"
    model_base="${model_base%.gguf}"
    local model_stripped
    model_stripped=$(echo "$model_base" | sed -E 's/[-_](UD-)?Q[0-9]+_[A-Z0-9]+(_[A-Z0-9]+)*$//')
    local mmproj_path
    mmproj_path=$(_llama_find_mmproj "$model_path" 2>/dev/null || echo "")

    echo "🗑  Target: ${model_path##*/}"
    if [ -f "$mmproj_path" ]; then
        echo "🗑  Vision: ${mmproj_path##*/}"
    fi

    printf "Delete these files? [y/N] "
    read -r confirm
    if [[ "${confirm:-n}" =~ ^[Yy]$ ]]; then
        rm -v "$model_path" 2>&1 | sed 's|^.*|  ✓ Removed |'
        if [ -f "$mmproj_path" ]; then
            rm -v "$mmproj_path" 2>&1 | sed 's|^.*|  ✓ Removed |'
        fi
    fi
}

_llama_show() {
    local model_query="$1"
    [ -z "$model_query" ] && { echo "Usage: llama show <model>"; return 1; }
    local model_path
    model_path=$(_llama_find_model "$model_query") || return 1
    echo "▶ Showing info for: ${model_path##*/}"
    llama-cli --model "$model_path" -p "" -n 1 --no-display 2>&1 | head -40
}

_llama_stop() {
    if _llama_server_running; then
        curl -sf "http://${LLM_SERVER_HOST}:${LLM_SERVER_PORT}/v1/chat/completions" > /dev/null 2>&1
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
    if _llama_server_running; then
        echo "Server is running at http://${LLM_SERVER_HOST}:${LLM_SERVER_PORT}"
        echo ""
        local pids
        pids=$(pgrep -f "llama-server" 2>/dev/null)
        if [ -n "$pids" ]; then
            echo "PID(s): $(echo $pids | tr '\n' ' ')"
        fi
        echo ""
        curl -sf "http://${LLM_SERVER_HOST}:${LLM_SERVER_PORT}/v1/models" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for m in data.get('data', []):
        print(f\"  Model: {m.get('id', '?')}\")
except: pass
" 2>/dev/null
    else
        echo "No server running."
    fi
    echo ""
}

_llama_bench() {
    local model_query="$1"
    [ -z "$model_query" ] && { echo "Usage: llama bench <model>"; return 1; }
    local model_path
    model_path=$(_llama_find_model "$model_query") || return 1
    echo "▶ Benchmarking: ${model_path##*/}"
    llama-bench -m "$model_path" -n 256 -p 512 -ngl "$LLM_DEFAULT_GPU_LAYERS" "$@"
}

_llama_register_opencode() {
    local filename="$1"
    local model_id="${filename%.gguf}"
    local config_file="$HOME/.config/opencode/opencode.json"
    [ ! -f "$config_file" ] && return

    python3 -c "
import json, sys
config_path = sys.argv[1]
model_id = sys.argv[2]
try:
    with open(config_path, 'r') as f:
        config = json.load(f)
    models = config.setdefault('provider', {}).setdefault('llama.cpp', {}).setdefault('models', {})
    if model_id not in models:
        friendly = model_id.replace('-UD-Q4_K_XL', '').replace('-Q4_K_M', '').replace('-Q5_K_M', '').replace('-Q8_0', '')
        friendly = ' '.join(friendly.split('-'))
        models[model_id] = {
            'name': f'{friendly} (local)',
            'limit': {'context': 32768, 'output': 8192}
        }
        with open(config_path, 'w') as f:
            json.dump(config, f, indent=2)
        print(f'  Registered {model_id} in opencode config')
except Exception as e:
    print(f'  Warning: could not register model: {e}', file=sys.stderr)
" "$config_file" "$model_id" 2>/dev/null
}

_llama_ask() {
    local model_query="$1"; shift
    [[ -z "$model_query" || -z "$*" ]] && { echo "Usage: llama ask <model> <prompt>"; return 1; }
    local model_path
    model_path=$(_llama_find_model "$model_query") || return 1
    llama-cli --model "$model_path" --n-gpu-layers "$LLM_DEFAULT_GPU_LAYERS" --ctx-size "$LLM_DEFAULT_CTX" \
        --prompt "$*" --n-predict 1024 --no-display-prompt --log-disable 2>/dev/null
    echo ""
}

_llama_pipe() {
    local model_query="$1"; shift
    local instruction="$1"; shift
    local file_path=""
    [[ -n "$1" && -f "$1" ]] && { file_path="$1"; shift; }
    [[ -z "$model_query" || -z "$instruction" ]] && { echo "Usage: llama pipe <model> <instruction> [file]"; return 1; }
    local model_path
    model_path=$(_llama_find_model "$model_query") || return 1
    local stdin_content
    if [[ -n "$file_path" ]]; then
        stdin_content=$(cat "$file_path")
    else
        stdin_content=$(cat)
    fi
    llama-cli --model "$model_path" --n-gpu-layers "$LLM_DEFAULT_GPU_LAYERS" --ctx-size "$LLM_DEFAULT_CTX" \
        --prompt "${instruction}\n${stdin_content}" --n-predict 2048 --no-display-prompt --log-disable 2>/dev/null
    echo ""
}

_llama_help() {
    echo ""
    echo "Usage: llama <subcommand> [options]"
    echo ""
    echo "Subcommands:"
    echo "  run <model> [args]     Run model interactively (llama-cli)"
    echo "  serve <model> [args]   Start OpenAI-compatible API server"
    echo "  list [-a]              List local models (-a shows mmproj files)"
    echo "  pull <repo-or-url>     Pull a model from Hugging Face"
    echo "  rm|remove <model>      Remove a model and its mmproj"
    echo "  show <model>           Show model info"
    echo "  stop                   Stop running server"
    echo "  ps                     Show server status"
    echo "  bench <model>          Run benchmark"
    echo "  ask <model> <prompt>   One-shot question, exit after answer"
    echo "  pipe <model> <instr> [file]  Pipe stdin or file into model with instruction"
    echo "  help                   Show this help"
    echo ""
    echo "Environment variables:"
    echo "  LLM_MODELS_DIR         Model storage directory (default: \$HOME/.llama/llama-models)"
    echo "  LLM_DEFAULT_CTX        Context size (default: 32768)"
    echo "  LLM_DEFAULT_GPU_LAYERS GPU layers (default: 99)"
    echo "  LLM_SERVER_HOST        Server host (default: 127.0.0.1)"
    echo "  LLM_SERVER_PORT        Server port (default: 11434)"
    echo ""
    echo "🦙 \033[2mllama.cpp\033[0m"
}

llama-ask() {
    _llama_ask "$@"
}

llama-pipe() {
    _llama_pipe "$@"
}

if [[ -n "$BASH_VERSION" ]]; then
    _llama_bash_complete() {
        local cur="${COMP_WORDS[COMP_CWORD]}"
        local prev="${COMP_WORDS[COMP_CWORD-1]}"
        local subcmds="run serve list pull rm remove show stop ps bench ask pipe help"

        if [[ ${#COMP_WORDS[@]} -eq 2 ]]; then
            COMPREPLY=( $(compgen -W "$subcmds" -- "$cur") )
            return
        fi

        if [[ ${#COMP_WORDS[@]} -eq 3 ]]; then
            case "$prev" in
                run|serve|rm|remove|show|bench|ask|pipe)
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
        if [[ ${#COMP_WORDS[@]} -eq 2 ]]; then
            if [[ -d "$LLM_MODELS_DIR" ]]; then
                local models=()
                while IFS= read -r -d '' f; do
                    local bname="${f##*/}"
                    models+=("${bname%.gguf}")
                done < <(find "$LLM_MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null | sort -z)
                COMPREPLY=( $(compgen -W "${models[*]}" -- "$cur") )
            fi
        fi
    }
    complete -F _llama_ask_complete llama-ask

    _llama_pipe_complete() {
        local cur="${COMP_WORDS[COMP_CWORD]}"
        if [[ ${#COMP_WORDS[@]} -eq 2 ]]; then
            if [[ -d "$LLM_MODELS_DIR" ]]; then
                local models=()
                while IFS= read -r -d '' f; do
                    local bname="${f##*/}"
                    models+=("${bname%.gguf}")
                done < <(find "$LLM_MODELS_DIR" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null | sort -z)
                COMPREPLY=( $(compgen -W "${models[*]}" -- "$cur") )
            fi
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
            'show:Show model info'
            'ps:Show running server info'
            'stop:Stop the running server'
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
                    run|serve|remove|show|bench|ask|pipe)
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

# ─────────────────────────────────────────────
echo "🦙 \033[2mllama.cpp\033[0m"
