#!/usr/bin/env bash
# install_vllm_tooling.sh
# - Creates /opt/vllm-venv with vLLM + Torch (CUDA if available)
# - Adds /usr/local/bin/vllmapi wrapper for easy serving

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

apt-get update -y
apt-get install -y python3-venv python3-pip python3-dev jq curl

VENV="/opt/vllm-venv"
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
fi

# shellcheck disable=SC1091
source "$VENV/bin/activate"
pip install --upgrade pip wheel

# Try CUDA torch first; fall back to CPU if CUDA wheels fail
echo "== Installing PyTorch (CUDA wheels first, then CPU fallback) =="
if ! pip install --extra-index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio; then
  echo "   CUDA wheels failed; installing CPU wheels."
  pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
fi

# vLLM core
pip install "vllm>=0.5.0" huggingface_hub

deactivate

# Wrapper
cat >/usr/local/bin/vllmapi <<'EOF'
#!/usr/bin/env bash
# vllmapi: run vLLM OpenAI-compatible server from /opt/vllm-venv
set -euo pipefail
VENV="/opt/vllm-venv"
exec "$VENV/bin/python" -m vllm.entrypoints.openai.api_server "$@"
EOF
chmod +x /usr/local/bin/vllmapi

echo
echo "✔ vLLM installed."
echo "   Venv   : /opt/vllm-venv"
echo "   Runner : vllmapi (e.g., vllmapi --model meta-llama/Llama-3.1-8B-Instruct --port 11435)"

