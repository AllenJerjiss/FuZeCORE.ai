#!/bin/bash
set -e

REQUIRED_RUST_VERSION=1.82.0


# Check rustc version
if command -v rustc >/dev/null 2>&1; then
    INSTALLED_VERSION=$(rustc --version | awk '{print $2}')
    if [ "$(printf '%s\n' "$REQUIRED_RUST_VERSION" "$INSTALLED_VERSION" | sort -V | head -n1)" != "$REQUIRED_RUST_VERSION" ]; then
        echo "rustc version $INSTALLED_VERSION is too old. Upgrading to $REQUIRED_RUST_VERSION..."
        curl https://sh.rustup.rs -sSf | sh -s -- -y
        source $HOME/.cargo/env
        rustup update stable
    else
        echo "rustc version $INSTALLED_VERSION meets requirements."
    fi
else
    echo "rustc not found. Installing Rust $REQUIRED_RUST_VERSION..."
    curl https://sh.rustup.rs -sSf | sh -s -- -y
    source $HOME/.cargo/env
    rustup update stable
fi

# Ensure $HOME/.cargo/bin is in PATH persistently
if ! grep -q 'export PATH="$HOME/.cargo/bin:$PATH"' "$HOME/.bashrc"; then
    echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> "$HOME/.bashrc"
    echo "Added $HOME/.cargo/bin to PATH in ~/.bashrc. Please restart your shell for changes to take effect."
else
    echo "$HOME/.cargo/bin already in PATH in ~/.bashrc."
fi

# Check for cargo
if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo not found. Please ensure Rust installation completed successfully."
    exit 1
fi

# Install system dependencies for reqwest (OpenSSL)
if ! pkg-config --exists openssl; then
    echo "OpenSSL development libraries not found. Installing..."
    if [ -x "$(command -v apt-get)" ]; then
        sudo apt-get update && sudo apt-get install -y pkg-config libssl-dev
    elif [ -x "$(command -v dnf)" ]; then
        sudo dnf install -y pkgconf-pkg-config openssl-devel
    elif [ -x "$(command -v yum)" ]; then
        sudo yum install -y pkgconfig openssl-devel
    else
        echo "Please install OpenSSL development libraries manually."
        exit 1
    fi
else
    echo "OpenSSL development libraries found."
fi

echo "All requirements met. You can now run: cargo build"

# Install cargo-tarpaulin for code coverage
if ! command -v cargo-tarpaulin >/dev/null 2>&1; then
    echo "Installing cargo-tarpaulin for code coverage..."
    cargo install cargo-tarpaulin
else
    echo "cargo-tarpaulin already installed."
fi
