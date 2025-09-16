# FuZeCORE.ai

## 🚀 Modern LLM Benchmarking & Refinery Platform

FuZeCORE.ai provides a comprehensive, production-ready platform for benchmarking Large Language Models across multiple inference stacks with clean architecture, robust infrastructure, and user-friendly interfaces.

## 🏛️ Architecture Overview

```
benchmark.sh (lightweight CLI)
    ↓ delegates to
ust.sh (unified orchestrator) 
    ↓ uses
common.sh (shared infrastructure)
    ↓ orchestrates
Individual stack scripts (ollama, vLLM, llama.cpp, Triton)
```

## 🎯 Quick Start

### Simple Benchmarking
```bash
# Benchmark Ollama with all models
./benchmark.sh --stack ollama

# Benchmark specific models with debug
./benchmark.sh --stack vLLM --model gemma3 --debug

# Multi-GPU Ollama benchmarking
./benchmark.sh --stack ollama --gpu 0,1 --debug

# Clean and benchmark llama.cpp
./benchmark.sh --clean --stack llama.cpp
```

### Available Options
- `--stack STACK`: Target stack (ollama | vLLM | llama.cpp | Triton)
- `--model PATTERN`: Model pattern/regex to match  
- `--gpu LIST`: GPU specification (e.g., "0,1" for multi-GPU)
- `--debug`: Enable debug mode with verbose logging
- `--clean`: Clean benchmark artifacts before running
- `--help`: Show detailed usage information

## 🏗️ Infrastructure Features

### Modern Shared Library (`common/common.sh`)
- **400+ lines** of production-ready shared utilities
- **Standardized logging**: `info()`, `warn()`, `error()`, `ok()` with color coding
- **Robust error handling**: `error_exit()`, structured validation, graceful failures
- **Resource management**: Automatic temp file cleanup, service lifecycle management
- **CSV validation**: Data integrity checks for benchmark results

### Comprehensive Testing (`common/test_common.sh`)
- **Full test suite**: 13/13 unit tests covering all shared functions ✅
- **Assertion framework**: `assert_equals()`, `assert_contains()`, `assert_file_exists()`
- **Isolated testing**: Each test runs independently with proper cleanup
- **Continuous validation**: Automated testing ensures reliability

### Production Installation (`common/install.sh`)
- **System & user modes**: Automatic detection of installation requirements
- **Dependency validation**: Pre-flight checks for required commands
- **Safe deployment**: Backup/restore capability with conflict resolution
- **Path management**: Intelligent binary placement in `/usr/local/bin` or `~/.local/bin`

### Unified Orchestrator (`ust.sh`)
- **Smart root escalation**: Only escalates privileges when necessary
- **Global command routing**: Single entry point for all stack operations
- **Environment integration**: Uses shared infrastructure for consistent behavior
- **Comprehensive help**: Built-in documentation for all commands

## 📊 Stack Support

### Supported Inference Stacks
- **Ollama**: Complete integration with auto-tuning and GPU optimization
- **vLLM**: High-performance inference with multi-GPU support
- **llama.cpp**: Native CPU/GPU inference with GGUF export
- **Triton**: NVIDIA Triton Inference Server integration

### GPU & Hardware Management
- **Multi-GPU support**: Intelligent GPU detection and allocation
- **CUDA optimization**: Proper CUDA_VISIBLE_DEVICES handling
- **Resource profiling**: Automatic hardware capability detection
- **Performance tuning**: Stack-specific optimization strategies

## 📁 Project Structure

### Core Components
```
├── benchmark.sh                    # Lightweight CLI interface
├── factory/LLM/refinery/stack/
│   ├── ust.sh                     # Unified orchestrator
│   ├── common/
│   │   ├── common.sh              # Shared infrastructure library
│   │   ├── test_common.sh         # Test suite (13/13 tests)
│   │   ├── install.sh             # Installation framework
│   │   └── README.md              # Technical documentation (8,604 lines)
│   ├── ollama/                    # Ollama stack implementation
│   ├── vLLM/                      # vLLM stack implementation
│   ├── llama.cpp/                 # llama.cpp stack implementation
│   └── Triton/                    # Triton stack implementation
```

### Environment & Configuration
```
└── factory/LLM/refinery/stack/env/
    ├── templates/                 # Environment templates
    ├── explore/                   # Aggressive exploration configs
    ├── preprod/                   # Conservative pre-production configs
    └── prod/                      # Production-ready configs
```

## 🔧 Advanced Usage

### Direct Orchestrator Access
For advanced control, use the unified orchestrator directly:
```bash
cd factory/LLM/refinery/stack
./ust.sh --help                   # Show all available commands
./ust.sh ollama benchmark         # Direct stack benchmarking
./ust.sh analyze --stack ollama   # Analyze results
./ust.sh clean-bench --yes        # Clean benchmark artifacts
```

### Environment Management
```bash
# Generate environment files
cd factory/LLM/refinery/stack/env
./generate-envs.sh --mode explore --include "gemma3|llama"

# Use custom environment files
./ust.sh @custom.env ollama benchmark
```

## 📊 Data Management

### Benchmark Results
- **Aggregate CSV**: `factory/LLM/refinery/benchmarks.csv` (historical data)
- **Best results**: `factory/LLM/refinery/benchmarks.best*.csv` (optimized variants)
- **Run logs**: `/var/log/fuze-stack/` (detailed execution logs)
- **Analysis reports**: Automated performance analysis and ranking

### Result Analysis
```bash
# Analyze specific stack results
./ust.sh analyze --stack ollama

# Generate comprehensive reports
./ust.sh summarize-benchmarks

# Collect results from multiple runs
./ust.sh collect-results --all
```

## 🧪 Quality Assurance

### Testing Infrastructure
- **Unit tests**: 13/13 tests passing for shared infrastructure ✅
- **Integration tests**: Cross-component functionality validated ✅
- **Real-world validation**: Tested with actual LLM workloads ✅
- **Error handling**: All error paths tested and documented ✅

### Code Quality
- **Shellcheck compliance**: All scripts pass static analysis ✅
- **Documentation coverage**: Complete API documentation with examples ✅
- **Error recovery**: Graceful failure handling and cleanup ✅
- **Performance optimization**: Efficient resource utilization ✅

## 📖 Documentation

### Technical Documentation
- **Infrastructure docs**: `factory/LLM/refinery/stack/common/README.md` (8,604 lines)
- **Stack-specific guides**: Individual README files for each stack
- **API reference**: Complete function documentation with examples
- **Installation guides**: System and user installation procedures

### Getting Help
```bash
./benchmark.sh --help            # CLI usage and examples
./ust.sh --help                  # Orchestrator commands
./ust.sh <stack> --help          # Stack-specific options
```

## 🚀 Recent Improvements

### Infrastructure Modernization
- ✅ **Shared library foundation** with standardized utilities
- ✅ **Comprehensive test suite** with 100% function coverage  
- ✅ **Production installation framework** with safety checks
- ✅ **Unified orchestrator** with smart privilege management
- ✅ **Lightweight CLI** with clean separation of concerns

### Performance & Reliability
- ✅ **Multi-GPU optimization** for parallel model processing
- ✅ **Robust error handling** with graceful failure recovery
- ✅ **Resource management** with automatic cleanup
- ✅ **Service lifecycle** management with health checks
- ✅ **Data validation** for benchmark result integrity

### Developer Experience
- ✅ **Clean architecture** with modular, maintainable code
- ✅ **Comprehensive documentation** with practical examples
- ✅ **Automated testing** ensuring reliable operation
- ✅ **User-friendly CLI** with clear help and examples
- ✅ **Technical debt elimination** through systematic refactoring

---

**FuZeCORE.ai** - Production-ready LLM benchmarking with modern infrastructure and clean architecture.