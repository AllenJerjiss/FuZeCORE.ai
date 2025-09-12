#!/usr/bin/env bash
# install_triton_tooling.sh
# - Installs Docker + NVIDIA Container Toolkit
# - Pulls Triton server and SDK images
# - Installs perf_analyzer to /usr/local/bin
# - Creates /FuZe/triton/models for your model repo

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

apt-get update -y
apt-get install -y curl ca-certificates gnupg lsb-release jq

# Docker (Ubuntu)
if ! command -v docker >/dev/null 2>&1; then
  echo "== Installing Docker =="
  apt-get install -y docker.io
  systemctl enable --now docker
fi

# NVIDIA Container Toolkit
if ! dpkg -l | grep -q nvidia-container-toolkit; then
  echo "== Installing NVIDIA Container Toolkit =="
  distribution=$(. /etc/os-release; echo ${ID}${VERSION_ID})
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.gpg] https://#' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -y
  apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
fi

mkdir -p /FuZe/triton/models

# Pull Triton server + SDK images (adjust tag if you want)
SERVER_IMG="nvcr.io/nvidia/tritonserver:24.05-py3"
SDK_IMG="nvcr.io/nvidia/tritonserver:24.05-py3-sdk"

docker pull "$SERVER_IMG"
docker pull "$SDK_IMG"

# Extract perf_analyzer from SDK image
echo "== Installing perf_analyzer =="
docker rm -f triton-sdk-extract >/dev/null 2>&1 || true
docker create --name triton-sdk-extract "$SDK_IMG" bash >/dev/null

# Try common install locations
docker cp triton-sdk-extract:/opt/tritonserver/bin/perf_analyzer /usr/local/bin/perf_analyzer 2>/dev/null || true
docker cp triton-sdk-extract:/workspace/install/bin/perf_analyzer /usr/local/bin/perf_analyzer 2>/dev/null || true
docker rm -f triton-sdk-extract >/dev/null

if [ -x /usr/local/bin/perf_analyzer ]; then
  chmod +x /usr/local/bin/perf_analyzer
  echo "   perf_analyzer installed to /usr/local/bin/perf_analyzer"
else
  echo "   Warning: could not locate perf_analyzer in SDK image (paths changed?)."
  echo "   You can run it inside the SDK container as a fallback:"
  echo "     docker run --rm --gpus all -it $SDK_IMG /opt/tritonserver/bin/perf_analyzer --help"
fi

# Convenience runner script for Triton
cat >/usr/local/bin/triton-run <<EOF
#!/usr/bin/env bash
# triton-run: run Triton server on a given HTTP port with a model repo
set -euo pipefail
HTTP_PORT=\${1:-8000}
REPO_DIR=\${2:-/FuZe/triton/models}
IMG="${SERVER_IMG}"
exec docker run --rm --gpus all \\
  -p \${HTTP_PORT}:8000 -p 8001:8001 -p 8002:8002 \\
  -v "\${REPO_DIR}":/models \\
  "\${IMG}" tritonserver --model-repository=/models --http-port=8000 --grpc-port=8001 --metrics-port=8002
EOF
chmod +x /usr/local/bin/triton-run

echo
echo "✔ Triton tooling ready."
echo "   Model repo : /FuZe/triton/models"
echo "   Server     : docker run … ${SERVER_IMG} (or use: triton-run 8000 /FuZe/triton/models)"
echo "   Analyzer   : /usr/local/bin/perf_analyzer"

