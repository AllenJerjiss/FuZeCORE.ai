#!/bin/bash
set -e
. "$HOME/.cargo/env"
echo "Running cargo check..."
cargo check --all --release --locked --verbose
echo "Running cargo clippy..."
cargo clippy --all --release --locked --verbose -- -D warnings
echo "Building project..."
RUSTFLAGS="-D warnings" cargo build --all --release --locked --verbose


echo "Running tests..."
RUSTFLAGS="-D warnings" cargo test --all --release --locked --verbose

echo "Running code coverage with cargo-tarpaulin..."
cargo tarpaulin --tests --ignore-tests
