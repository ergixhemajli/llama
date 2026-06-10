# ~/.llama Wrapper — Project Notes

## Architecture
- Main script: `~/.llama/llama-aliases.sh` (MEANT TO BE SOURCED, not executed directly)
- Modular files: `~/.llama/llama.d/*.sh` (sourced in dependency order)
- User zsh config: `~/.zshrc` sources via `source ~/.llama/llama-aliases.sh`
- p10k (powerlevel10k) with instant prompt enabled

## Known Bug: _llama_convert naming mismatch
- `llama.d/llama-convert.sh` defines `_llama_convert_hf_to_gguf()`
- `llama-aliases.sh` case statement calls `_llama_convert` (line: `shift; _llama_convert "$@"`)
- These names don't match — `_llama_convert` is never defined
- Fix: Either rename function in llama-convert.sh to `_llama_convert`, or update case to call `_llama_convert_hf_to_gguf`

## Environment
- macOS Tahoe 26.5 (25F71) arm64, Darwin 25.5.0
- MacBook Pro 16" M5 Max, 38338 MiB MTL memory
- Python 3.9.6 (system) — pip packages at ~/Library/Python/3.9/
- pip packages: gguf-0.18.0, torch, transformers (installed with `--user` for Python 3.9)
- llama.cpp binary: v9550 (Homebrew), supports `--spec-type draft-mtp`
- NOT compiled with native `gemma4_assistant` architecture support

## Gemma-4 MTP
- Base models: gemma-4-26B-A4B-it, gemma-4-31B-it (UD-Q4_K_XL)
- Assistant dirs (safetensors): `gemma-4-*-it-assistant/` with `model.safetensors`
- `llama serve` passes `--spec-type draft-mtp` and llama.cpp auto-detects safetensors
- Assistant GGUF files exist for 31B but NOT for 26B
- Detection fix: `_llama_binary_supports_gemma_assistant()` should grep for `draft-mtp` not `gemma4_assistant`

## Convert Infrastructure
- Scripts at: `~/.llama/convert/` (converted_hf_to_gguf.py, conversion/, gguf-py/)
- Requires: gguf, torch, transformers (all installed for Python 3.9 user site)
- Python PATH includes ~/Library/Python/3.9/bin for user-installed packages

## User Preferences / UX Conventions (durable)
- Pulled model names should be concise in `llama list`; details belong in separate columns (QUANT/SIZE/PROVIDER/TECH/PATH), not in a long NAME field.
- `llama ps`/serve UX should avoid long wrapped model titles that break readability.
- `llama serve` model selection should be intuitive and interactive (arrow-key `fzf` picker) and based on the same table semantics as `llama list`.
- Do NOT use numeric-only selection prompts for model choice.
- Do NOT show duplicate/noisy preview pane in the `fzf` picker if it repeats the same row info.
- `llama` tab-completion for serving should avoid suggesting MTP helper models directly (to reduce confusion).
- `llama doctor` should detect missing Gemma mmproj files and explicitly tell user to rerun with the download flag to fetch missing files.
