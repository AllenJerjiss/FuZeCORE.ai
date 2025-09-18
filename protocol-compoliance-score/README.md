# Protocol Compliance Score

## Overview
This Rust project automates protocol compliance scoring, code hygiene enforcement, and deep root cause analysis (RCA) for AI and LLM workflows. It features strict build/test validation, maximized code coverage, and interactive protocols for continuous improvement.

## Features
- **Automated Build & Test**: Enforced via `build.sh` and Rust toolchain scripts.
- **Strict Code Hygiene**: Static analysis, clippy, and build fail on warnings.
- **Unit & Integration Testing**: Comprehensive coverage for core logic, edge cases, and CLI/main flows.
- **Coverage Reporting**: Integrated with cargo-tarpaulin for decision/branch coverage.
- **Interactive Protocols**: Protocols for compliance, RCA, and coverage improvement.

## Protocols
### 1. COMMUNICATION_PROTOCOL
- Defines the core communication rules for LLMs and agents.
- Enforced via markdown (`COMMUNICATION_PROTOCOL.md`) and JSON (`COMMUNICATION_PROTOCOL.json`).

### 2. IMPROVE_CODE_COVERAGE
- Interactive protocol for maximizing code coverage.
- Guides analysis, improvement, and validation steps.
- Markdown: `IMPROVE_CODE_COVERAGE.md`
- JSON: `IMPROVE_CODE_COVERAGE.json`

### 3. 5LRCA
- Five-layer root cause analysis protocol.
- Markdown: `5LRCA.md`
- JSON: `5LRCA.json`

## Usage
- Run `./build.sh` to build, lint, test, and generate coverage reports.
- Use the protocol runner to invoke specific protocols (e.g., coverage improvement).
- Add new protocols by creating corresponding `.md` and `.json` files and updating the runner logic.

## Test Coverage
- All critical code paths, error branches, and CLI logic are covered by unit and integration tests.
- Coverage reports are generated automatically after each build.

## Folder Structure
- `lib.rs`: Core logic and protocol runner.
- `generate_pcs.rs`: CLI/main entry point.
- `tests/`: Unit and integration tests for all features and protocols.
- `build.sh`, `install.sh`: Automation scripts.
- Protocol files: Markdown and JSON for each protocol.

## How to Contribute
- Fork the repo and create a feature branch.
- Add new protocols or improve coverage by following the IMPROVE_CODE_COVERAGE protocol.
- Submit pull requests with clear descriptions and coverage validation.

---
Maintained by AllenJerjiss and contributors.
