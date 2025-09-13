# FuZeCORE.ai

Benchmarking & Refinery
- Top-level orchestrator: `./benchmark.sh`
  - Runs install → cleanup → benchmark → export (for Ollama) → analyze across stacks
  - Auto-discovers model env files in `LLM/refinery/stack/*.env`
  - Auto-discovers stacks under `LLM/refinery/stack/` (ollama, llama.cpp, vLLM, Triton)
  - Flags:
    - `--stack "ollama llama.cpp vLLM Triton"` to limit stacks
    - `--model REGEX` (repeatable) to filter env files by name

Stack scripts live under `LLM/refinery/stack/`:
- `ust.sh` (per-stack driver): `./LLM/refinery/stack/ust.sh <stack> [command]`
- Common tools: `LLM/refinery/stack/common/{preflight,analyze,collect-results,summarize-benchmarks}.sh`
- Per-stack benchmarks: `LLM/refinery/stack/{ollama,vLLM,llama.cpp,Triton}/benchmark.sh`

Aggregates and summaries
- Aggregate CSV: `LLM/refinery/benchmarks.csv` (appends on each run)
- Derived bests: `LLM/refinery/benchmarks.best*.csv`
- Human summary per run: `/var/log/fuze-stack/wrapper_best_<ts>.txt`
