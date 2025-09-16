# FuZe LLM Stack Infrastructure

Modern, production-ready benchmarking infrastructure for LLM inference stacks with clean architecture, shared utilities, and unified orchestration.

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

## 🚀 Quick Start

### Simple CLI Usage
```bash
# From repository root
./benchmark.sh --stack ollama                    # Benchmark Ollama
./benchmark.sh --stack vLLM --model gemma3       # Benchmark vLLM with gemma3 models
./benchmark.sh --stack ollama --gpu 0,1 --debug  # Multi-GPU with debug
./benchmark.sh --clean --stack llama.cpp         # Clean then benchmark
```

### Direct Orchestrator Usage
```bash
cd factory/LLM/refinery/stack
./ust.sh --help                          # Show all commands
./ust.sh ollama benchmark                # Direct stack benchmarking
./ust.sh @custom.env ollama benchmark    # Use custom environment file
./ust.sh analyze --stack ollama          # Analyze results
./ust.sh clean-bench --yes               # Clean benchmark artifacts
```

## 🏗️ Infrastructure Components

### Unified Orchestrator (`ust.sh`)
- **Smart root escalation**: Only escalates privileges when necessary
- **Global command routing**: Single entry point for all stack operations
- **Environment file support**: Load settings via `@environment.env`
- **Integrated help system**: Built-in documentation for all commands
- **Common infrastructure**: Uses shared library for consistent behavior

### Shared Infrastructure (`common/common.sh`)
- **400+ lines** of production-ready utilities
- **Standardized logging**: `info()`, `warn()`, `error()`, `ok()` with color coding
- **Robust error handling**: `error_exit()`, structured validation
- **Resource management**: Automatic temp file cleanup, service lifecycle
- **CSV validation**: Data integrity checks for benchmark results

### Testing Framework (`common/test_common.sh`)
- **13 unit tests** covering all shared functions ✅
- **Assertion framework**: Comprehensive test utilities
- **Isolated testing**: Independent test execution with cleanup
- **Automated validation**: Continuous testing ensures reliability

### Installation Framework (`common/install.sh`)
- **System & user modes**: Automatic installation detection
- **Dependency validation**: Pre-flight checks for requirements
- **Safe deployment**: Backup/restore with conflict resolution
- **Path management**: Intelligent binary placement

## 📊 Supported Stacks

### Ollama
```bash
./ust.sh ollama install                   # Install/upgrade
./ust.sh ollama service-cleanup           # Reset service
./ust.sh ollama benchmark                 # Run benchmarks
./ust.sh ollama cleanup-variants --yes    # Clean variants
./ust.sh ollama export-gguf               # Export to GGUF
```

### vLLM
```bash
./ust.sh vLLM install                     # Install vLLM
./ust.sh vLLM benchmark                   # Run benchmarks
```

### llama.cpp
```bash
./ust.sh llama.cpp install               # Install llama.cpp
./ust.sh llama.cpp benchmark             # Run benchmarks
```

### Triton
```bash
./ust.sh Triton install                  # Install Triton
./ust.sh Triton benchmark                # Run benchmarks
```

## 🔧 System Management

### GPU & Hardware
```bash
./ust.sh gpu-prepare                     # Setup NVIDIA drivers/CUDA
./ust.sh preflight                       # Environment checks
```

### Data Management
```bash
./ust.sh analyze --stack ollama          # Analyze results
./ust.sh collect-results --all           # Collect historical data
./ust.sh summarize-benchmarks            # Generate reports
./ust.sh clean-bench --yes               # Clean artifacts
```

### Log Management
```bash
./ust.sh migrate-logs                    # Migrate logs to system
```

## 🌍 Environment Management

### Environment Files
```bash
# Use specific environment file
./ust.sh @env/explore/custom.env ollama benchmark

# Generate environment files
cd env
./generate-envs.sh --mode explore --include "gemma3|llama"
```

### Environment Variables
- `BENCH_NUM_CTX`: Context length for benchmarks
- `BENCH_NUM_PREDICT`: Number of tokens to generate
- `TEMPERATURE`: Generation temperature (default: 0.0)
- `VERBOSE`: Enable verbose logging (0/1)
- `DEBUG`: Enable debug mode (0/1)
- `CUDA_VISIBLE_DEVICES`: GPU specification
- `OLLAMA_SCHED_SPREAD`: Enable multi-GPU spreading

### Environment Tiers
- **explore/**: Aggressive exploration configurations
- **preprod/**: Conservative pre-production settings  
- **prod/**: Production-ready configurations

## 📁 File Structure

```
factory/LLM/refinery/stack/
├── ust.sh                          # Unified orchestrator
├── common/
│   ├── common.sh                    # Shared infrastructure (400+ lines)
│   ├── test_common.sh               # Test suite (13 tests)
│   ├── install.sh                   # Installation framework
│   ├── README.md                    # Technical documentation (8,604 lines)
│   ├── analyze.sh                   # Result analysis
│   ├── collect-results.sh           # Data collection
│   ├── summarize-benchmarks.sh      # Report generation
│   ├── clean-bench.sh               # Cleanup utilities
│   ├── gpu-setup.sh                 # GPU/CUDA setup
│   ├── migrate-logs.sh              # Log migration
│   └── *.awk                        # Analysis libraries
├── env/
│   ├── templates/                   # Environment templates
│   ├── explore/                     # Exploration configs
│   ├── preprod/                     # Pre-production configs
│   ├── prod/                        # Production configs
│   └── generate-envs.sh             # Environment generator
├── ollama/
│   ├── benchmark.sh                 # Ollama benchmarking
│   ├── install.sh                   # Ollama installation
│   ├── service-cleanup.sh           # Service management
│   ├── cleanup-variants.sh          # Variant cleanup
│   └── export-gguf.sh               # GGUF export
├── vLLM/
│   ├── benchmark.sh                 # vLLM benchmarking
│   └── install.sh                   # vLLM installation
├── llama.cpp/
│   ├── benchmark.sh                 # llama.cpp benchmarking
│   ├── install.sh                   # llama.cpp installation
│   └── import-gguf-from-ollama.sh   # GGUF import
└── Triton/
    ├── benchmark.sh                 # Triton benchmarking
    └── install.sh                   # Triton installation
```

## 🧪 Testing & Validation

### Running Tests
```bash
cd common
./test_common.sh                     # Run all tests
./test_common.sh test_info_function  # Run specific test
```

### Test Coverage
- ✅ **13/13 tests passing** for shared infrastructure
- ✅ **Function coverage**: All shared library functions tested
- ✅ **Error handling**: Error conditions validated
- ✅ **Integration**: Cross-component functionality verified

## 📊 Data Pipeline

### CSV Schema
All stacks write results using a standardized 16-column CSV schema:
- Timestamp, Host, Stack, Model information
- Performance metrics (tokens/sec, latency, throughput)
- Configuration details (context, prediction length, temperature)
- Resource utilization (GPU, memory)

### Aggregation
- **benchmarks.csv**: Historical aggregate data
- **benchmarks.best*.csv**: Optimized variant results
- **Log files**: Detailed execution traces in `/var/log/fuze-stack/`

### Analysis
- **Performance comparison**: Baseline vs variant analysis
- **Trend analysis**: Historical performance tracking
- **Resource optimization**: GPU utilization analysis
- **Model ranking**: Best performing configurations

## 🚀 Recent Improvements

### Architecture Modernization
- ✅ **Clean separation**: CLI → orchestrator → shared infrastructure
- ✅ **Shared utilities**: 400+ lines of production-ready code
- ✅ **Comprehensive testing**: 13/13 unit tests passing
- ✅ **Smart privilege management**: Root escalation only when needed
- ✅ **Installation framework**: System and user deployment modes

### Performance & Reliability  
- ✅ **Multi-GPU support**: Parallel processing with OLLAMA_SCHED_SPREAD
- ✅ **Error recovery**: Graceful failure handling and cleanup
- ✅ **Resource management**: Automatic temp file and service cleanup
- ✅ **Data validation**: CSV integrity checks and validation
- ✅ **Service resilience**: Robust startup/shutdown procedures

### Developer Experience
- ✅ **Code quality**: Eliminated duplication and technical debt
- ✅ **Documentation**: 8,604 lines of technical documentation
- ✅ **Consistent interfaces**: Standardized argument parsing and help
- ✅ **Maintainable code**: Modular architecture with clear boundaries
- ✅ **Automated testing**: Continuous validation of core functionality

---

**Modern LLM benchmarking infrastructure** with production-ready reliability and clean architecture.