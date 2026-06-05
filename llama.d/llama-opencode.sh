#!/usr/bin/env bash
# llama-opencode.sh — opencode model registration/unregistration

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

_llama_unregister_opencode() {
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
    models = config.get('provider', {}).get('llama.cpp', {}).get('models', {})
    if model_id in models:
        del models[model_id]
        with open(config_path, 'w') as f:
            json.dump(config, f, indent=2)
        print(f'  Unregistered {model_id} from opencode config')
except Exception as e:
    print(f'  Warning: could not unregister model: {e}', file=sys.stderr)
" "$config_file" "$model_id" 2>/dev/null
}
