# FuZeCORE.ai

Benchmarking & Refinery
- Top-level orchestrator: `./benchmark.sh`
  - Runs install → service cleanup → benchmark → export (Ollama only) → analyze across stacks
  - Discovers model env files under `factory/LLM/refinery/stack/env/**`
  - Discovers stacks under `factory/LLM/refinery/stack/` (ollama, llama.cpp, vLLM, Triton)
  - Flags:
    - `--stack "ollama llama.cpp vLLM Triton"` or positional stacks to limit stacks
    - `--model REGEX` (repeatable) filters by env filename or embedded `INCLUDE_MODELS`
    - `--env explore|preprod|prod` controls env generation/selection
      - `explore` → aggressive template → env/explore
      - `preprod` → conservative template → env/preprod
      - `prod` → copies preprod envs to env/prod “as‑is”
  - Prints best CSV paths at start; finishes with Global‑best section and current run analysis.

Stack scripts live under `factory/LLM/refinery/stack/`:
- `ust.sh` (per-stack driver): `./factory/LLM/refinery/stack/ust.sh <stack> [command]`
- Common tools: `factory/LLM/refinery/stack/common/{preflight,analyze,collect-results,summarize-benchmarks}.sh`
- Per-stack benchmarks: `factory/LLM/refinery/stack/{ollama,vLLM,llama.cpp,Triton}/benchmark.sh`

Env templates & generator
- Explore (aggressive): `factory/LLM/refinery/stack/env/templates/FuZeCORE-explore.env.template`
- Preprod (conservative): `factory/LLM/refinery/stack/env/templates/FuZeCORE-preprod.env.template`
- Generator: `factory/LLM/refinery/stack/env/generate-envs.sh`
  - `--mode explore|preprod|both` (default: both)
  - `--promote --all` or `--promote --model REGEX` to copy preprod envs to prod (immutable)

Aggregates and summaries
- Aggregate CSV: `factory/LLM/refinery/benchmarks.csv` (appends each run)
- Derived bests: `factory/LLM/refinery/benchmarks.best*.csv`
- Human summary per run: `/var/log/fuze-stack/wrapper_best_<ts>.txt`
- Uniform summary columns across sections; aliased model names for readability.
