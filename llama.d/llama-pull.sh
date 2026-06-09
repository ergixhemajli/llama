#!/usr/bin/env bash
# llama-pull.sh — Model download and registration

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
        if ! command -v hf >/dev/null 2>&1; then
            echo "Error: no GGUF files found in $hf_repo and 'hf' CLI is not installed." >&2
            echo "Install with: pip install -U huggingface_hub hf_transfer" >&2
            return 1
        fi
        local mlx_out_dir="$LLM_MODELS_DIR/${hf_repo##*/}"
        echo "▶ No GGUF files found; downloading full repo (MLX or non-GGUF): $hf_repo…"
        hf download "$hf_repo" --local-dir "$mlx_out_dir"
        echo "✓ Saved to $mlx_out_dir"
        return
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
    local chosen_base="${chosen##*/}"
    local chosen_stem="${chosen_base%.gguf}"
    local filename="${hf_repo##*/}-${chosen_stem}.gguf"
    local out_file="$LLM_MODELS_DIR/$filename"
    echo "▶ Downloading $chosen…"
    if command -v hf >/dev/null 2>&1; then
        hf download "$hf_repo" --include "$chosen" --local-dir "$LLM_MODELS_DIR"
        if [ -f "$LLM_MODELS_DIR/$chosen" ]; then
            mv -f "$LLM_MODELS_DIR/$chosen" "$out_file"
        elif [ -f "$LLM_MODELS_DIR/${chosen##*/}" ]; then
            mv -f "$LLM_MODELS_DIR/${chosen##*/}" "$out_file"
        fi
    else
        curl -L --progress-bar -o "$out_file" "$dl_url"
    fi
    echo "✓ Saved to $out_file"

    if [[ "$filename" != mmproj* ]]; then
        _llama_register_integrations "$filename"
        _llama_model_meta_set "$filename" "$hf_repo" "$(_llama_repo_tech "$hf_repo")"
    fi

    if [[ "$filename" != mmproj* ]]; then
        local mmproj_remote="mmproj-F16.gguf"
        local http_status
        http_status=$(curl -sf -o /dev/null -w "%{http_code}" -L --max-time 5 "https://huggingface.co/${hf_repo}/resolve/main/${mmproj_remote}" 2>/dev/null)
        if [ "$http_status" = "200" ]; then
            local model_base="${filename%.gguf}"
            local stripped_base
            stripped_base=$(echo "$model_base" | sed -E 's/[-_]((UD|UDT)-)?Q[0-9]+_[A-Z0-9]+(_[A-Z0-9]+)*$//')
            local mmproj_out="$LLM_MODELS_DIR/mmproj-F16-${stripped_base}.gguf"
            echo ""
            printf "Vision projector (mmproj-F16) found — download it? [Y/n] "
            read -r mmproj_confirm
            if [[ "${mmproj_confirm:-Y}" =~ ^[Yy]$ ]]; then
                echo "▶ Downloading mmproj-F16 -> ${mmproj_out##*/}…"
                if command -v hf >/dev/null 2>&1; then
                    hf download "$hf_repo" --include "$mmproj_remote" --local-dir "$LLM_MODELS_DIR"
                    [ -f "$LLM_MODELS_DIR/$mmproj_remote" ] && mv -f "$LLM_MODELS_DIR/$mmproj_remote" "$mmproj_out"
                else
                    curl -L --progress-bar -o "$mmproj_out" "https://huggingface.co/${hf_repo}/resolve/main/${mmproj_remote}"
                fi
                echo "✓ Saved to $mmproj_out"
            fi
        fi
    fi
}
