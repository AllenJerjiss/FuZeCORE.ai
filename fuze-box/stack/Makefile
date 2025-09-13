SHELL := /bin/bash

# Resolve to this stack directory
STACK_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
UST := $(STACK_DIR)ust.sh

# Common knobs (can be overridden at invocation)
INCLUDE_MODELS ?=
EXHAUSTIVE ?= 0
FAST_MODE ?= 1
BENCH_NUM_PREDICT ?= 64
BENCH_NUM_CTX ?= 4096
TEMPERATURE ?= 0.0

.PHONY: help gpu-prepare preflight \
        ollama-install ollama-service-cleanup ollama-store-cleanup ollama-cleanup-variants ollama-export-gguf ollama-bench \
        vllm-bench llamacpp-bench triton-bench \
        tail-ollama-csv tail-vllm-csv tail-llamacpp-csv tail-triton-csv

help:
	@echo "Targets:"
	@echo "  gpu-prepare             Install NVIDIA driver/CUDA toolkit if GPU detected"
	@echo "  preflight               Run environment checks for all stacks"
	@echo "  ollama-install           Install/upgrade Ollama + stock service"
	@echo "  ollama-service-cleanup   Reset persistent Ollama service on :11434"
	@echo "  ollama-store-cleanup     Migrate/merge stores into /FuZe/models/ollama (use ARGS=...)"
	@echo "  ollama-cleanup-variants  Remove baked variants (from created list)"
	@echo "  ollama-export-gguf       Export GGUFs from Ollama models and write llama.cpp env map"
	@echo "  ollama-bench             Run Ollama benchmark (FAST_MODE=$(FAST_MODE), PRED=$(BENCH_NUM_PREDICT))"
	@echo "  vllm-bench               Run vLLM benchmark"
	@echo "  llamacpp-bench           Run llama.cpp benchmark"
	@echo "  triton-bench             Run Triton benchmark"
	@echo "  tail-*-csv               Tail latest CSV for each stack"
	@echo ""
	@echo "Common knobs (override on make cmdline):"
	@echo "  INCLUDE_MODELS='^gemma3:4b-it-fp16$' EXHAUSTIVE=0 FAST_MODE=1 BENCH_NUM_PREDICT=64 BENCH_NUM_CTX=4096 TEMPERATURE=0.0"

ollama-install:
	sudo -E $(UST) ollama install

ollama-service-cleanup:
	sudo -E $(UST) ollama service-cleanup

# Optional: pass extra flags via ARGS (e.g., ARGS="--canon /FuZe/models/ollama --alt /var/lib/ollama")
ollama-store-cleanup:
	sudo -E $(UST) ollama store-cleanup $(ARGS)

ollama-cleanup-variants:
	sudo -E $(UST) ollama cleanup-variants --from-created $(STACK_DIR)logs/ollama_created_*.txt --force --yes

ollama-export-gguf:
	./$(UST) ollama export-gguf $(ARGS)

ollama-bench:
	sudo -E env INCLUDE_MODELS='$(INCLUDE_MODELS)' \
	  EXHAUSTIVE='$(EXHAUSTIVE)' FAST_MODE='$(FAST_MODE)' \
	  BENCH_NUM_PREDICT='$(BENCH_NUM_PREDICT)' BENCH_NUM_CTX='$(BENCH_NUM_CTX)' \
	  TEMPERATURE='$(TEMPERATURE)' \
	  $(UST) ollama

vllm-bench:
	BENCH_NUM_CTX='$(BENCH_NUM_CTX)' TEMPERATURE='$(TEMPERATURE)' $(UST) vLLM

llamacpp-bench:
	BENCH_NUM_CTX='$(BENCH_NUM_CTX)' TEMPERATURE='$(TEMPERATURE)' $(UST) llama.cpp

triton-bench:
	BENCH_NUM_CTX='$(BENCH_NUM_CTX)' BENCH_NUM_PREDICT='$(BENCH_NUM_PREDICT)' $(UST) Triton

tail-ollama-csv:
	@ls -t $(STACK_DIR)logs/ollama_bench_*.csv 2>/dev/null | head -n1 | xargs -r tail -n 40

tail-vllm-csv:
	@ls -t $(STACK_DIR)logs/vllm_bench_*.csv 2>/dev/null | head -n1 | xargs -r tail -n 40

tail-llamacpp-csv:
	@ls -t $(STACK_DIR)logs/llamacpp_bench_*.csv 2>/dev/null | head -n1 | xargs -r tail -n 40

tail-triton-csv:
	@ls -t $(STACK_DIR)logs/triton_bench_*.csv 2>/dev/null | head -n1 | xargs -r tail -n 40
gpu-prepare:
	sudo -E $(UST) gpu-prepare

preflight:
	$(UST) preflight
