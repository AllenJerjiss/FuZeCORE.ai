# RCAL5DRILLDOWN - `refine-and-bake` Failure Analysis (2025-09-19)

## Phase 1: Triage & Reconnaissance

### 1.1 Symptom Identification

- **Primary Symptom:** The main script `factory/refine-and-bake-ollama-gpt-oss-20b-std.sh` fails during the benchmarking phase.
- **Secondary Symptom:** The script logs `"No working variants found"` repeatedly for each GPU endpoint.
- **Tertiary Symptom:** The script exits prematurely with exit code 141.
- **User Observation:** "i'm runnig it but it still says it can't find any variants...what is happening?"

### 1.2 Initial Data Gathering & Evidence

- **Log Files:** The primary evidence is the output from the last failed script execution.
- **Configuration Files:** The behavior is defined by a series of shell scripts, primarily `ollama-benchmark.sh`, and the `systemd` unit files it generates.
- **Environment:** The failure occurs within temporary `systemd` services (`ollama-test-*.service`) created for benchmarking. The main, persistent `ollama.service` appears to function correctly.

### 1.3 Triage Summary

The script successfully sets up the environment and starts the temporary benchmark services. However, when the `ollama-benchmark.sh` script attempts to run a benchmark via `curl` against these services, the requests fail. The error handling within the script interprets these failures as a zero tokens-per-second result (`0.00 tok/s`). After multiple consecutive failures, the tuning loop gives up and reports that no working variants could be found. The `EOF` error captured in previous debugging sessions strongly suggests that the Ollama server's child process, responsible for loading the model, is crashing. The root cause is likely an environmental difference between the working persistent `ollama.service` and the failing temporary `ollama-test-*.service` units.

---
*This RCA is now in progress. Subsequent phases will be documented below.*
