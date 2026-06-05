#!/usr/bin/env bash
# llama-list.sh — Model listing

_llama_list() {
    local show_all=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--all) show_all=true; shift ;;
            *) shift ;;
        esac
    done
    python3 - "$LLM_MODELS_DIR" "$_LLAMA_MODEL_INDEX_FILE" "$show_all" <<'PY'
import json
import os
import re
import sys

models_dir, index_file, show_all = sys.argv[1], sys.argv[2], sys.argv[3].lower() == "true"

index = {"models": {}}
if os.path.exists(index_file):
    try:
        with open(index_file, "r") as f:
            index = json.load(f)
    except Exception:
        index = {"models": {}}

def strip_quant(stem: str) -> str:
    return re.sub(r'[-_]((UD|UDT)-)?(IQ[0-9]+_[A-Z0-9]+|Q[0-9]+_[A-Z0-9]+|Q[0-9]+_[A-Z0-9]+_[A-Z0-9]+|Q[0-9]+_[0-9]+|BF16|F16)$', '', stem)

def infer_provider(stem: str) -> str:
    s = stem.lower()
    if s.startswith("gemma-4-"):
        return "google"
    if s.startswith("qwen3.6-"):
        return "unsloth"
    return "local"

def assistant_exists(stem: str) -> bool:
    base = strip_quant(stem)
    for d in (base + "-assistant", base.lower() + "-assistant"):
        if os.path.isdir(os.path.join(models_dir, d)):
            return True
    return False

def infer_tech(stem: str, has_assistant: bool) -> str:
    s = stem.lower()
    if "mlx" in s:
        return "MLX"
    if "mtp" in s:
        return "MTP"
    if has_assistant:
        return "GGUF+assistant"
    return "GGUF"

def quant_suffix(stem: str) -> str:
    m = re.search(r'[-_]((UD|UDT)-)?(IQ[0-9]+_[A-Z0-9]+|Q[0-9]+_[A-Z0-9]+|Q[0-9]+_[A-Z0-9]+_[A-Z0-9]+|Q[0-9]+_[0-9]+|BF16|F16)$', stem)
    return m.group(0).lstrip('-_') if m else ""

def fmt_size(path: str) -> str:
    n = os.path.getsize(path)
    units = [(1<<40, "T"), (1<<30, "G"), (1<<20, "M"), (1<<10, "K")]
    for d, u in units:
        if n >= d:
            v = n / d
            s = f"{v:.1f}" if v < 10 else f"{v:.0f}"
            return f"{s}{u}"
    return f"{n}B"

rows = []
if not os.path.isdir(models_dir):
    print()
    print(f"{'NAME':38} {'SIZE':10} {'PROVIDER':10} {'TECH':14} PATH")
    print(f"{'-'*38} {'-'*10} {'-'*10} {'-'*14} {'-'*28}")
    print()
    raise SystemExit(0)

for entry in sorted(os.listdir(models_dir)):
    if not entry.endswith(".gguf"):
        continue
    if not show_all and entry.startswith("mmproj"):
        continue
    path = os.path.join(models_dir, entry)
    if not os.path.isfile(path):
        continue
    stem = entry[:-5]
    meta = index.get("models", {}).get(entry, {})
    repo = meta.get("repo", "")
    provider = meta.get("provider", "") or (repo.split("/", 1)[0] if "/" in repo else "")
    has_assistant = assistant_exists(stem)
    tech = meta.get("tech", "")
    if not provider:
        provider = infer_provider(stem)
    if not tech:
        tech = infer_tech(stem, has_assistant)
    elif tech == "GGUF" and has_assistant:
        tech = "GGUF+assistant"
    name = repo.split("/", 1)[1] if "/" in repo else stem
    q = quant_suffix(stem)
    if q:
        name = f"{name} [{q}]"
    rows.append((name, fmt_size(path), provider, tech, path))

print()
name_w = max(38, max((len(r[0]) for r in rows), default=0))
size_w = max(10, max((len(r[1]) for r in rows), default=0))
provider_w = max(10, max((len(r[2]) for r in rows), default=0))
tech_w = max(14, max((len(r[3]) for r in rows), default=0))

print(f"{'NAME':<{name_w}} {'SIZE':<{size_w}} {'PROVIDER':<{provider_w}} {'TECH':<{tech_w}} PATH")
print(f"{'-'*name_w} {'-'*size_w} {'-'*provider_w} {'-'*tech_w} {'-'*28}")
for row in rows:
    print(f"{row[0]:<{name_w}} {row[1]:<{size_w}} {row[2]:<{provider_w}} {row[3]:<{tech_w}} {row[4]}")
print()
PY
}
