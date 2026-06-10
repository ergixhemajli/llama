#!/usr/bin/env bash
# Saved memory review for reference
cat <<'EOF'
## User: ergix, macOS M5 Max, zsh/p10k, Norwegian locale
## Prefers binaries over building from source
## Project: ~/.llama/ modular llama.cpp wrapper (llama.d/, llama-aliases.sh, convert/)

## Failures:
# 1. _llama_binary_supports_gemma_assistant() grepped for 'gemma4_assistant' in --help — wrong, use 'draft-mtp'
# 2. Gemma assistant MTP: safetensors→GGUF conversion needed via convert_hf_to_gguf.py
# 3. Conversion requires: torch, transformers, gguf Python packages
# 4. Missing functions in router: _llama_stop, _llama_complete, _llama_ps, _llama_run, _llama_serve
# 5. Relative _LLAMA_DIR causes "Not a directory" — always use absolute path
# 6. macOS Python 3.9.6 has LibreSSL 2.8.3 (NotOpenSSLWarning)

## Key: gemma4 MTP uses --spec-type draft-mtp, not a dedicated CLI flag
## Assistant repos: AtomicChat/gemma-4-*-it-assistant-GGUF
## mmproj works in serve; MTP assistant loading is bottleneck
EOF
