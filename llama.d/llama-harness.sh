#!/usr/bin/env bash
# llama-harness.sh — OpenCode/Pi model registration helpers

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
    print(f'  Warning: could not register model in opencode: {e}', file=sys.stderr)
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
    print(f'  Warning: could not unregister model from opencode: {e}', file=sys.stderr)
" "$config_file" "$model_id" 2>/dev/null
}

_llama_register_pi() {
    local filename="$1"
    local model_id="${filename%.gguf}"
    local models_file="$HOME/.pi/agent/models.json"
    local settings_file="$HOME/.pi/agent/settings.json"

    mkdir -p "$(dirname "$models_file")"

    python3 -c "
import json, os, sys
models_path, model_id = sys.argv[1], sys.argv[2]

def friendly_name(mid: str) -> str:
    s = mid.replace('-UD-Q4_K_XL', '').replace('-Q4_K_M', '').replace('-Q5_K_M', '').replace('-Q8_0', '')
    return '{} (local)'.format(' '.join(s.split('-')))

try:
    data = {}
    if os.path.exists(models_path):
        with open(models_path, 'r') as f:
            data = json.load(f)

    providers = data.setdefault('providers', {})
    provider = providers.setdefault('llama.cpp', {})
    provider.setdefault('baseUrl', 'http://127.0.0.1:11434/v1')
    provider.setdefault('api', 'openai-completions')
    provider.setdefault('apiKey', 'ollama')
    compat = provider.setdefault('compat', {})
    compat.setdefault('supportsDeveloperRole', False)
    compat.setdefault('supportsReasoningEffort', False)

    models = provider.setdefault('models', [])
    exists = any(isinstance(m, dict) and m.get('id') == model_id for m in models)
    if not exists:
        models.append({
            'id': model_id,
            'name': friendly_name(model_id),
            'reasoning': True,
            'input': ['text'],
            'contextWindow': 32768,
            'maxTokens': 8192,
            'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}
        })
        with open(models_path, 'w') as f:
            json.dump(data, f, indent=2)
        print(f'  Registered {model_id} in pi models config')
except Exception as e:
    print(f'  Warning: could not register model in pi models: {e}', file=sys.stderr)
" "$models_file" "$model_id" 2>/dev/null

    [ ! -f "$settings_file" ] && return
    python3 -c "
import json, sys
settings_path, model_id = sys.argv[1], sys.argv[2]
try:
    with open(settings_path, 'r') as f:
        settings = json.load(f)
    enabled = settings.get('enabledModels')
    if isinstance(enabled, list) and model_id not in enabled:
        enabled.append(model_id)
        with open(settings_path, 'w') as f:
            json.dump(settings, f, indent=2)
        print(f'  Added {model_id} to pi enabledModels')
except Exception as e:
    print(f'  Warning: could not update pi enabledModels: {e}', file=sys.stderr)
" "$settings_file" "$model_id" 2>/dev/null
}

_llama_unregister_pi() {
    local filename="$1"
    local model_id="${filename%.gguf}"
    local models_file="$HOME/.pi/agent/models.json"
    local settings_file="$HOME/.pi/agent/settings.json"

    [ ! -f "$models_file" ] || python3 -c "
import json, sys
models_path, model_id = sys.argv[1], sys.argv[2]
try:
    with open(models_path, 'r') as f:
        data = json.load(f)
    provider = data.get('providers', {}).get('llama.cpp', {})
    models = provider.get('models')
    if isinstance(models, list):
        new_models = [m for m in models if not (isinstance(m, dict) and m.get('id') == model_id)]
        if len(new_models) != len(models):
            provider['models'] = new_models
            with open(models_path, 'w') as f:
                json.dump(data, f, indent=2)
            print(f'  Unregistered {model_id} from pi models config')
except Exception as e:
    print(f'  Warning: could not unregister model from pi models: {e}', file=sys.stderr)
" "$models_file" "$model_id" 2>/dev/null

    [ ! -f "$settings_file" ] || python3 -c "
import json, sys
settings_path, model_id = sys.argv[1], sys.argv[2]
try:
    with open(settings_path, 'r') as f:
        settings = json.load(f)
    enabled = settings.get('enabledModels')
    if isinstance(enabled, list) and model_id in enabled:
        settings['enabledModels'] = [m for m in enabled if m != model_id]
        with open(settings_path, 'w') as f:
            json.dump(settings, f, indent=2)
        print(f'  Removed {model_id} from pi enabledModels')
except Exception as e:
    print(f'  Warning: could not update pi enabledModels: {e}', file=sys.stderr)
" "$settings_file" "$model_id" 2>/dev/null
}

_llama_register_integrations() {
    local filename="$1"
    [ -z "$filename" ] && { echo "Usage: llama opencode|pi <model-file-or-id>"; return 1; }
    _llama_register_opencode "$filename"
    _llama_register_pi "$filename"
}

_llama_unregister_integrations() {
    local filename="$1"
    [ -z "$filename" ] && return 1
    _llama_unregister_opencode "$filename"
    _llama_unregister_pi "$filename"
}
