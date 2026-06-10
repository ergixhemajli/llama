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
            'limit': {'context': int(os.environ.get('LLM_DEFAULT_CTX', '196608')), 'output': 8192}
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
            'contextWindow': int(os.environ.get('LLM_DEFAULT_CTX', '196608')),
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
    wanted = f'llama.cpp/{model_id}'
    if isinstance(enabled, list) and wanted not in enabled:
        enabled.append(wanted)
        with open(settings_path, 'w') as f:
            json.dump(settings, f, indent=2)
        print(f'  Added {wanted} to pi enabledModels')
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
    namespaced = f'llama.cpp/{model_id}'
    if isinstance(enabled, list):
        new_enabled = [m for m in enabled if m not in (model_id, namespaced)]
        if len(new_enabled) != len(enabled):
            settings['enabledModels'] = new_enabled
            with open(settings_path, 'w') as f:
                json.dump(settings, f, indent=2)
            print(f'  Removed {model_id} from pi enabledModels')
except Exception as e:
    print(f'  Warning: could not update pi enabledModels: {e}', file=sys.stderr)
" "$settings_file" "$model_id" 2>/dev/null
}

_llama_sync_integrations() {
    local target="${1:-both}"

    python3 - "$target" "$LLM_MODELS_DIR" "$HOME/.config/opencode/opencode.json" "$HOME/.pi/agent/models.json" "$HOME/.pi/agent/settings.json" <<'PY'
import json
import os
import re
import sys
from typing import Dict, List, Set


def load_json(path: str, default):
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception:
        return default


def save_json(path: str, data) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def friendly_name(mid: str) -> str:
    s = mid
    for token in ("-UD-Q4_K_XL", "-UD-Q2_K_XL", "-Q4_K_M", "-Q5_K_M", "-Q8_0"):
        s = s.replace(token, "")
    return "{} (local)".format(" ".join(s.split("-")))


def discover_models(models_dir: str) -> List[str]:
    if not os.path.isdir(models_dir):
        return []
    out: List[str] = []
    for entry in sorted(os.listdir(models_dir)):
        if not entry.endswith(".gguf"):
            continue
        if entry.startswith("mmproj"):
            continue
        out.append(entry[:-5])
    return out


def is_pure_mtp_provider(mid: str, all_ids: Set[str]) -> bool:
    if "-MTP-" not in mid:
        return False
    prefix = mid.split("-MTP-", 1)[0]
    paired_qat = any(other != mid and other.startswith(prefix + "-qat-") for other in all_ids)
    return paired_qat


target, models_dir, op_path, pi_models_path, pi_settings_path = sys.argv[1:6]
all_ids = discover_models(models_dir)
all_set = set(all_ids)
usable_ids = sorted(mid for mid in all_ids if not is_pure_mtp_provider(mid, all_set))
usable_set = set(usable_ids)

print(f"Sync source: {len(all_ids)} models in llama dir, {len(usable_ids)} usable for harnesses")
if all_ids:
    dropped = [mid for mid in all_ids if mid not in usable_set]
    if dropped:
        print("  Dropping pure MTP provider models:")
        for mid in dropped:
            print(f"    - {mid}")

summary = []

if target in ("opencode", "both"):
    op = load_json(op_path, {})
    provider = op.setdefault("provider", {}).setdefault("llama.cpp", {})
    models = provider.setdefault("models", {})
    if not isinstance(models, dict):
        models = {}
        provider["models"] = models

    existing_keys = set(models.keys())
    removed = sorted(existing_keys - usable_set)
    added = sorted(usable_set - existing_keys)

    for mid in removed:
        del models[mid]
    for mid in added:
        models[mid] = {
            "name": friendly_name(mid),
            "limit": {"context": int(os.environ.get("LLM_DEFAULT_CTX", "196608")), "output": 8192},
        }

    if target == "opencode" or os.path.exists(op_path):
        save_json(op_path, op)
        summary.append(f"opencode: +{len(added)} / -{len(removed)}")

if target in ("pi", "both"):
    pi_models = load_json(pi_models_path, {})
    provider = pi_models.setdefault("providers", {}).setdefault("llama.cpp", {})
    provider.setdefault("baseUrl", "http://127.0.0.1:11434/v1")
    provider.setdefault("api", "openai-completions")
    provider.setdefault("apiKey", "ollama")
    compat = provider.setdefault("compat", {})
    compat.setdefault("supportsDeveloperRole", False)
    compat.setdefault("supportsReasoningEffort", False)

    models = provider.setdefault("models", [])
    if not isinstance(models, list):
        models = []
    existing_by_id: Dict[str, dict] = {}
    for m in models:
        if isinstance(m, dict) and isinstance(m.get("id"), str):
            existing_by_id[m["id"]] = m

    new_models: List[dict] = []
    added = 0
    for mid in usable_ids:
        if mid in existing_by_id:
            new_models.append(existing_by_id[mid])
        else:
            added += 1
            new_models.append(
                {
                    "id": mid,
                    "name": friendly_name(mid),
                    "reasoning": True,
                    "input": ["text"],
                    "contextWindow": int(os.environ.get("LLM_DEFAULT_CTX", "196608")),
                    "maxTokens": 8192,
                    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                }
            )

    removed = len(existing_by_id) - (len(new_models) - added)
    provider["models"] = new_models
    save_json(pi_models_path, pi_models)

    settings = load_json(pi_settings_path, {})
    enabled = settings.get("enabledModels")
    if not isinstance(enabled, list):
        enabled = []

    op_keys: Set[str] = set()
    if os.path.exists(op_path):
        op_data = load_json(op_path, {})
        op_models = op_data.get("provider", {}).get("llama.cpp", {}).get("models", {})
        if isinstance(op_models, dict):
            op_keys = set(k for k in op_models.keys() if isinstance(k, str))

    known_local = set(all_ids) | set(existing_by_id.keys()) | op_keys

    new_enabled: List[str] = []
    seen = set()

    for item in enabled:
        if not isinstance(item, str):
            continue
        if item.startswith("llama.cpp/"):
            mid = item.split("/", 1)[1]
            if mid in usable_set and item not in seen:
                new_enabled.append(item)
                seen.add(item)
            continue
        if item in known_local:
            if item in usable_set:
                namespaced = f"llama.cpp/{item}"
                if namespaced not in seen:
                    new_enabled.append(namespaced)
                    seen.add(namespaced)
            continue

        if item not in seen:
            new_enabled.append(item)
            seen.add(item)

    for mid in usable_ids:
        namespaced = f"llama.cpp/{mid}"
        if namespaced not in seen:
            new_enabled.append(namespaced)
            seen.add(namespaced)

    settings["enabledModels"] = new_enabled
    save_json(pi_settings_path, settings)
    summary.append(f"pi: +{added} / -{removed} (models), enabled={len(new_enabled)}")

if summary:
    print("Sync complete:")
    for line in summary:
        print(f"  {line}")
else:
    print("Nothing to sync for target:", target)
PY
}

_llama_register_integrations() {
    local target="${1:-both}"
    shift || true
    local arg="${1:-}"

    if [ -z "$arg" ] || [ "$arg" = "sync" ] || [ "$arg" = "--sync" ]; then
        _llama_sync_integrations "$target"
        return $?
    fi

    local filename="$arg"
    case "$target" in
        opencode)
            _llama_register_opencode "$filename"
            ;;
        pi)
            _llama_register_pi "$filename"
            ;;
        *)
            _llama_register_opencode "$filename"
            _llama_register_pi "$filename"
            ;;
    esac
}

_llama_unregister_integrations() {
    local filename="$1"
    [ -z "$filename" ] && return 1
    _llama_unregister_opencode "$filename"
    _llama_unregister_pi "$filename"
}
