# FuZe LLM Stack Benchmarks

Unified driver and per‑stack benchmark scripts for Ollama, vLLM, llama.cpp, and Triton. All stacks write CSV with the same 16‑column schema. Summaries print with uniform columns across sections and use model aliases consistently.

## Drivers

- Orchestrator: `./benchmark.sh`
  - Discovers env files under `factory/LLM/refinery/stack/env/**`.
  - Flags:
    - `--stack "ollama llama.cpp vLLM Triton"` or positional stack names to limit stacks
    - `--model REGEX` (repeatable): filter env files by filename or embedded `INCLUDE_MODELS`
    - `--env explore|preprod|prod`:
      - `explore`: generate envs from aggressive template into `env/explore` and run
      - `preprod`: generate envs from conservative template into `env/preprod` and run
      - `prod`: copy envs from `env/preprod` to `env/prod` “as‑is”, then run
  - Prints best CSV destinations at start; ends with “Global best per model” then the current run analysis.
- Per-stack driver: `./factory/LLM/refinery/stack/ust.sh <stack> [command] [args...]`
- Stacks: `ollama`, `vLLM`, `llama.cpp`, `Triton`
- Default command: `benchmark`

Examples (always run with sudo -E)
- Run everything (all stacks, all envs): `./benchmark.sh`
- Only Gemma profiles on Ollama + llama.cpp: `./benchmark.sh --stack "ollama llama.cpp" --model gemma`
- Positional stacks: `./benchmark.sh --env explore --model '^gemma3:4b-it-fp16$' ollama`
- Per-stack, with env file: `sudo -E ./factory/LLM/refinery/stack/ust.sh @factory/LLM/refinery/stack/env/explore/FuZeCORE-gemma3-4b-it-fp16.env ollama`
- Ollama fast bench: `sudo -E FAST_MODE=1 EXHAUSTIVE=0 BENCH_NUM_PREDICT=64 ./factory/LLM/refinery/stack/ust.sh ollama`
- vLLM bench: `sudo -E ./factory/LLM/refinery/stack/ust.sh vLLM`
- llama.cpp bench: `sudo -E ./factory/LLM/refinery/stack/ust.sh llama.cpp`
- Triton bench (perf_analyzer): `sudo -E ./factory/LLM/refinery/stack/ust.sh Triton`
- GPU prepare (drivers/CUDA): `sudo ./factory/LLM/refinery/stack/ust.sh gpu-prepare`
- Preflight (env checks): `./factory/LLM/refinery/stack/ust.sh preflight`
- Migrate logs to system path: `sudo ./factory/LLM/refinery/stack/ust.sh migrate-logs`

Ollama management commands
- Install/upgrade + stock service: `sudo ./factory/LLM/refinery/stack/ust.sh ollama install`
- Persistent service reset (:11434): `sudo ./factory/LLM/refinery/stack/ust.sh ollama service-cleanup`
- Store migration to `/FuZe/models/ollama`: `sudo ./factory/LLM/refinery/stack/ust.sh ollama store-cleanup [--canon PATH --alt PATH]`
- Remove baked variants: `sudo ./factory/LLM/refinery/stack/ust.sh ollama cleanup-variants --from-created factory/LLM/refinery/stack/logs/ollama_created_*.txt --force --yes`
- Export GGUFs + llama.cpp env: `./factory/LLM/refinery/stack/ust.sh ollama export-gguf [--dest DIR] [--host HOST:PORT] [--include REGEX] [--exclude REGEX] [--env-out FILE]`

System prep
- `gpu-prepare`: detects NVIDIA GPU and installs driver + CUDA toolkit when needed via `common/gpu-setup.sh`. No-ops if no NVIDIA GPU is present.
- `preflight`   : runs environment checks for all stacks (GPU/driver/CUDA, binaries, services, ports, model dirs)

## Common Env Knobs (all stacks)

- `BENCH_NUM_CTX`: context length used or recorded in CSV (stack‑specific application)
- `BENCH_NUM_PREDICT`: number of tokens to generate per request (CSV and/or request)
- `TEMPERATURE`: generation temperature (0.0 default)

Logs and CSV
- Logs directory: `/var/log/fuze-stack` (override with `LOG_DIR`)
- Use `migrate-logs` to move old files from legacy paths and create symlinks.
- CSV header (16 columns): `ts,endpoint,unit,suffix,base_model,variant_label,model_tag,num_gpu,num_ctx,batch,num_predict,tokens_per_sec,gpu_label,gpu_name,gpu_uuid,gpu_mem_mib`
- `tokens_per_sec` is column 12 across all stacks
- Aggregate CSV: `factory/LLM/refinery/benchmarks.csv`
- Derived bests: `factory/LLM/refinery/benchmarks.best*.csv`

## Ollama Stack

Script: `factory/LLM/refinery/stack/ollama/benchmark.sh`

Fast mode (default)
- `FAST_MODE=1`: no tag baking; pass options at runtime
- `AUTO_NG=1`: auto‑derive `num_gpu` candidates from `layers.model` seen in systemd logs
- `NG_PERCENT_SET`: default `"100 90 75 60 50 40 30 20 10"` (tried high→low)
- `EXHAUSTIVE=0`: stop at first working config (set `1` to try all)
- `BENCH_NUM_PREDICT`, `BENCH_NUM_CTX`, `TEMPERATURE` included in request

Tag baking mode
- `FAST_MODE=0`: bakes `num_gpu` variants as tags and benches them
- Auto‑GC of non‑working variants unless `KEEP_FAILED_VARIANTS=1`

Discovery and filters
- Pulls base models from persistent daemon `:11434`
- Filters: `INCLUDE_MODELS` (regex), `EXCLUDE_MODELS` (regex)
- Alias prefix: set `ALIAS_PREFIX` (default `FuZeCORE-`) to prefix model aliases and variant names, e.g., `gemma3:4b-it-fp16 (alias FuZeCORE-gemma3-4b-it-fp16)`

Service handling
- Test units: `ollama-test-a.service` (`:11435`), `ollama-test-b.service` (`:11436`)
- Uses `OLLAMA_HOST=127.0.0.1:<port>` and `CUDA_VISIBLE_DEVICES=<GPU_UUID>`
- Readiness: `/api/tags`
- To bench on the stock daemon: `TEST_PORT_A=11434`

Other knobs
- `TIMEOUT_GEN`, `TIMEOUT_TAGS`, `WAIT_API_SECS`
- `OLLAMA_MODELS_DIR` (default `/FuZe/models/ollama`), `OLLAMA_BIN` (default `/usr/local/bin/ollama`)

Management helpers
- `ollama/install.sh`: installs/upgrades Ollama, normalizes stock service to use `/FuZe/models/ollama`
- `ollama/service-cleanup.sh`: forces a consistent persistent service on `:11434`
- `ollama/store-cleanup.sh`: merges/migrates stores into `/FuZe/models/ollama`
- `ollama/cleanup-variants.sh`: removes baked variant tags by pattern or from created list

CSV timing
- `eval_duration` is in nanoseconds; script converts to seconds for `tokens_per_sec`

## vLLM Stack

Script: `factory/LLM/refinery/stack/vLLM/benchmark.sh`

- Ports: `PORT_A=11435`, `PORT_B=11436`
- GPU binding: `CUDA_VISIBLE_DEVICES=<GPU_UUID>` per server process
- Models: edit `MODELS` list or override with `VLLM_MODEL_<alias>` envs
- Context: `BENCH_NUM_CTX` overrides `CTX` (`--max-model-len`)
- Tokens: `PRED` (or `BENCH_NUM_PREDICT`) controls `max_tokens`
- `TEMPERATURE` carried in request JSON
- Dtype and memory: `DTYPE` (float16/bfloat16/auto), `GPU_MEM_UTIL` (default 0.90)

Install auto‑GPU
- The vLLM installer detects NVIDIA GPUs and runs `common/gpu-setup.sh` to ensure the NVIDIA driver is installed before installing CUDA PyTorch wheels. CPU wheels are used only when no GPU or drivers are unavailable.

## llama.cpp Stack

Script: `factory/LLM/refinery/stack/llama.cpp/benchmark.sh`

- Ports: `PORT_A=11435`, `PORT_B=11436`
- Server binary: `LLAMACPP_BIN` (auto‑detects `llama-server`/`server`)
- Auto‑mapping: sources `llama.cpp/models.env` if present (generated by `ollama/export-gguf.sh`), which sets `LLAMACPP_PATH_<alias>` to GGUF paths.
- Models: sets `MODEL_DIR` and `MODELS` pattern list, or override with `LLAMACPP_PATH_<alias>`
- Sweep: `NGL_CANDIDATES` (e.g., `"-1 64 48 32 24 16 0"`)
- Context: `BENCH_NUM_CTX` overrides `CTX`; tokens via `PRED` or `BENCH_NUM_PREDICT`
- `TEMPERATURE` carried in `/completion` request

Install auto‑GPU
- The llama.cpp installer detects NVIDIA GPUs and runs `common/gpu-setup.sh` to install drivers and CUDA toolkit (nvcc) so GGML_CUDA builds are enabled. CPU build is used only when no GPU or nvcc remains unavailable.

## Triton Stack

Script: `factory/LLM/refinery/stack/Triton/benchmark.sh`

- Endpoints: `TRITON_HTTP_A=127.0.0.1:8000`, `TRITON_HTTP_B=127.0.0.1:8001`
- Models: `TRITON_MODELS` (pairs `name|alias`)
- Uses `perf_analyzer` if present; outputs throughput as `tokens_per_sec`
- Parity knobs into CSV only: `BENCH_NUM_CTX`, `BENCH_NUM_PREDICT` (no effect on perf)

## Templates and Env Generation

- Templates:
  - Explore (aggressive): `factory/LLM/refinery/stack/env/templates/FuZeCORE-explore.env.template`
  - Preprod (conservative): `factory/LLM/refinery/stack/env/templates/FuZeCORE-preprod.env.template`
- Generator: `factory/LLM/refinery/stack/env/generate-envs.sh`
  - `--mode explore|preprod|both` (default: both)
  - `--include REGEX`, `--host HOST:PORT`, `--overwrite`, `--dry-run`
  - `--promote --all` or `--promote --model REGEX` to copy preprod envs to prod “as‑is” (immutable)

## Notes

- Scripts aim to be idempotent and resilient to missing services.
- Variants: the top‑level wrapper preserves existing variants by default (set `VARIANT_CLEANUP=1` to allow cleanup).
- GGUF export: export uses `--overwrite`; set `GGUF_CLEAN=1` to clear old `*.gguf` before export.
- Summaries: use uniform columns across sections and aliases in output.
