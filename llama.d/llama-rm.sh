#!/usr/bin/env bash
# llama-rm.sh — Model removal

_llama_rm() {
    [ $# -eq 0 ] && { echo "Usage: llama remove|rm <model> [model2 ...]"; return 1; }

    local model_paths=()
    local mmproj_paths=()
    local query model_path mmproj_path p exists

    while [[ $# -gt 0 ]]; do
        query="$1"
        shift
        if ! model_path=$(_llama_find_model "$query" 2>/dev/null); then
            echo "  ! Skipping: model '$query' not found"
            continue
        fi

        exists=0
        for p in "${model_paths[@]}"; do
            [ "$p" = "$model_path" ] && { exists=1; break; }
        done
        [ "$exists" = "0" ] && model_paths+=("$model_path")

        mmproj_path=$(_llama_find_mmproj "$model_path" 2>/dev/null || echo "")
        if [ -n "$mmproj_path" ]; then
            exists=0
            for p in "${mmproj_paths[@]}"; do
                [ "$p" = "$mmproj_path" ] && { exists=1; break; }
            done
            [ "$exists" = "0" ] && mmproj_paths+=("$mmproj_path")
        fi
    done

    [ ${#model_paths[@]} -eq 0 ] && { echo "No matching models found."; return 1; }

    for p in "${model_paths[@]}"; do
        echo "🗑  Target: ${p##*/}"
    done
    for p in "${mmproj_paths[@]}"; do
        [ -f "$p" ] && echo "🗑  Vision: ${p##*/}"
    done

    printf "Delete these files? [y/N] "
    read -r confirm
    if [[ "${confirm:-n}" =~ ^[Yy]$ ]]; then
        for p in "${model_paths[@]}"; do
            if [ -f "$p" ]; then
                _llama_model_meta_remove "${p##*/}"
                _llama_unregister_integrations "${p##*/}"
                rm -v "$p" 2>&1 | sed 's|^.*|  ✓ Removed |'
            fi
        done
        for p in "${mmproj_paths[@]}"; do
            [ -f "$p" ] && rm -v "$p" 2>&1 | sed 's|^.*|  ✓ Removed |'
        done
    fi
}
