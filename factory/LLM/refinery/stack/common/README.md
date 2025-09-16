# FuZe Stack Common Utilities

A comprehensive suite of tools for managing, analyzing, and maintaining AI/ML benchmark infrastructure.

## 🚀 Quick Start

### Installation

```bash
# System-wide installation (requires sudo)
sudo ./install.sh

# User installation (no sudo required)
./install.sh --user

# Dry run to see what would be installed
./install.sh --dry-run
```

### Configuration

After installation, source the configuration:

```bash
# For system installation
source /etc/fuze-stack/config.env

# For user installation  
source ~/.config/fuze-stack/config.env

# Or add to your shell profile for permanent setup
echo 'source /etc/fuze-stack/config.env' >> ~/.bashrc
```

## 📋 Available Tools

### 🔍 Analysis & Reporting

#### `fuze-analyze` - Interactive Benchmark Analysis
Analyze benchmark CSV data with filtering and top-N reporting.

```bash
# Analyze latest results for any stack
fuze-analyze

# Analyze specific stack
fuze-analyze --stack ollama

# Filter by model regex
fuze-analyze --model "^gemma3" --top 10

# Analyze specific CSV file
fuze-analyze --csv /path/to/benchmark.csv
```

**Options:**
- `--stack STACK` - Target specific stack (ollama, vLLM, llama.cpp, Triton)
- `--csv PATH` - Analyze specific CSV file
- `--model REGEX` - Filter models by regex pattern
- `--top N` - Show top N results (default: 5)
- `--no-debug` - Minimal output
- `--no-top` - Skip top-N analysis

#### `fuze-summarize-benchmarks` - Comprehensive Reports
Generate detailed performance reports with multiple output formats.

```bash
# Generate summary with default settings
fuze-summarize-benchmarks

# Filter and generate markdown report
fuze-summarize-benchmarks --stack ollama --model "gemma3" --md-out report.md

# Top performers only
fuze-summarize-benchmarks --only-top --top 20
```

**Output Files:**
- `benchmarks.best.csv` - Best per (stack, model)
- `benchmarks.best.by_model.csv` - Best per model globally
- `benchmarks.best.by_host_model.csv` - Best per (host, model)

#### `fuze-collect-results` - Data Aggregation  
Consolidate benchmark results from all stacks into central CSV.

```bash
# Collect from all stacks
fuze-collect-results

# Custom output location
fuze-collect-results --out /path/to/combined.csv

# Specific stacks only
fuze-collect-results --stacks "ollama vLLM"
```

### 🧹 Maintenance & Cleanup

#### `fuze-clean-bench` - Safe Environment Cleanup
Clean benchmark artifacts with branch-aware environment detection.

```bash
# Dry run (safe default)
fuze-clean-bench

# Actually clean (requires explicit confirmation)
fuze-clean-bench --yes

# Clean specific environment
fuze-clean-bench --env explore --yes

# Keep latest N files
fuze-clean-bench --keep-latest 5 --yes

# Clean variants and env files too
fuze-clean-bench --variants --envs --yes
```

**Safety Features:**
- Dry-run by default
- Branch-based environment detection
- Production safety checks
- Keep-latest option

#### `fuze-migrate-logs` - Log Consolidation
Move logs to centralized system location with symlink backfill.

```bash
# Migrate logs (requires sudo for system paths)
sudo fuze-migrate-logs

# Custom destination
sudo fuze-migrate-logs --dest /custom/log/path

# Dry run first
sudo fuze-migrate-logs --dry-run
```

### 🖥️ System Setup

#### `fuze-gpu-setup` - Hardware Initialization
Automated NVIDIA GPU driver and CUDA toolkit installation.

```bash
# Check what would be installed
sudo fuze-gpu-setup --dry-run

# Install drivers and CUDA
sudo fuze-gpu-setup

# Skip driver installation
sudo fuze-gpu-setup --skip-driver

# Force reinstall
sudo fuze-gpu-setup --force
```

**Features:**
- GPU auto-detection
- Multiple CUDA version fallbacks
- Ubuntu/Debian package management
- Safe no-op on non-NVIDIA systems

#### `fuze-preflight` - System Validation
Comprehensive pre-benchmark system health checks.

```bash
# Run all checks
fuze-preflight

# Verbose output
VERBOSE=1 fuze-preflight
```

**Checks:**
- GPU drivers and CUDA
- Required system binaries
- Service status (ollama.service)
- Port availability
- Directory permissions

### 🔧 Development Tools

#### `test_common.sh` - Unit Testing
Test suite for common library functions.

```bash
# Run all tests
./test_common.sh

# Run with verbose output
VERBOSE=1 ./test_common.sh
```

## 📁 Architecture

```
stack/common/
├── common.sh              # Shared functions and configuration
├── install.sh             # Installation script
├── test_common.sh         # Unit tests
├── *.awk                  # AWK library files
├── analyze.sh             # Analysis tools
├── summarize-benchmarks.sh # Report generation
├── collect-results.sh     # Data aggregation  
├── clean-bench.sh         # Maintenance
├── migrate-logs.sh        # Log management
├── gpu-setup.sh           # Hardware setup
└── preflight.sh           # System validation
```

## 🔧 Configuration

### Environment Variables

```bash
# Core directories
LOG_DIR="/var/log/fuze-stack"           # Log directory
CONFIG_DIR="/etc/fuze-stack"            # Config directory

# Behavior settings  
ALIAS_PREFIX="LLM-FuZe-"               # Model name prefix
TOPN_DEFAULT=5                         # Default top N results
TIMEOUT_DEFAULT=30                     # Default timeout seconds
DRY_RUN=0                              # Enable dry-run mode
VERBOSE=0                              # Verbose logging
QUIET=0                                # Quiet mode

# Stack settings
SUPPORTED_STACKS="ollama vLLM llama.cpp Triton"
```

### Log Levels

```bash
LOG_LEVEL=1  # Error only
LOG_LEVEL=2  # Error + Warning  
LOG_LEVEL=3  # Error + Warning + Info (default)
LOG_LEVEL=4  # All messages including Debug
```

## 🎯 Usage Patterns

### Pre-Benchmark Workflow
```bash
# 1. System validation
fuze-preflight

# 2. Setup hardware (if needed)
sudo fuze-gpu-setup --dry-run
sudo fuze-gpu-setup

# 3. Clean previous runs
fuze-clean-bench --yes
```

### Post-Benchmark Analysis
```bash
# 1. Collect results from all stacks
fuze-collect-results

# 2. Generate reports
fuze-summarize-benchmarks --md-out latest_results.md

# 3. Interactive analysis
fuze-analyze --top 10
```

### Maintenance
```bash
# 1. Log consolidation
sudo fuze-migrate-logs

# 2. Cleanup old data
fuze-clean-bench --keep-latest 10 --yes

# 3. Validate system
fuze-preflight
```

## 🛠️ Advanced Features

### Dry-Run Mode
Most scripts support `--dry-run` to preview actions:

```bash
fuze-clean-bench        # Dry-run by default
fuze-gpu-setup --dry-run
fuze-migrate-logs --dry-run
```

### Error Handling
- Comprehensive input validation
- Graceful error recovery
- Detailed error messages
- Temp file cleanup on exit

### Safety Features
- Production environment protection
- Backup creation before destructive operations
- Confirmation prompts for dangerous actions
- Rollback capabilities where applicable

### Performance
- Efficient AWK-based CSV processing
- Parallel processing where possible
- Minimal external dependencies
- Optimized for large datasets

## 🔍 Troubleshooting

### Common Issues

**Missing Dependencies:**
```bash
# Install required tools on Ubuntu/Debian
sudo apt-get install awk sed jq curl git

# Verify installation
fuze-preflight
```

**Permission Issues:**
```bash
# Use user installation if sudo not available
./install.sh --user

# Check file permissions
ls -la /etc/fuze-stack/
```

**GPU Setup Problems:**
```bash
# Check GPU detection
fuze-gpu-setup --dry-run

# Verify drivers
nvidia-smi
nvcc --version
```

### Debug Mode
```bash
# Enable debug logging
export LOG_LEVEL=4
export VERBOSE=1

# Run with debug output
fuze-analyze --stack ollama
```

### Log Files
Check system logs for detailed error information:
```bash
# System logs
journalctl -u ollama.service

# Application logs  
tail -f /var/log/fuze-stack/*.log
```

## 🤝 Contributing

### Running Tests
```bash
# Run unit tests
./test_common.sh

# Test installation
./install.sh --dry-run

# Validate all scripts
for script in *.sh; do bash -n "$script"; done
```

### Code Style
- Use `set -euo pipefail` for safety
- Source `common.sh` for shared functions
- Include comprehensive error handling
- Add input validation
- Support dry-run mode
- Include usage documentation

### Adding New Scripts
1. Source `common.sh` for shared functionality
2. Add input validation and error handling
3. Support `--dry-run` and `--help`
4. Add to `install.sh` script list
5. Include unit tests where appropriate
6. Update documentation

## 📄 License

This software is part of the FuZeCORE.ai project. See project license for details.