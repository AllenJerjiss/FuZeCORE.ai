#!/usr/bin/env bash
set -euo pipefail
# Ensure a consistent persistent Ollama service on :11434 using OLLAMA_HOST

# 0) Vars
UNIT=/etc/systemd/system/ollama-persist.service
PORT=11434
MODELDIR=${MODELDIR:-/FuZe/models/ollama}
OLLAMA_BIN=${OLLAMA_BIN:-/usr/local/bin/ollama}

# 1) Unmask (and remove any /dev/null mask symlink)
if systemctl is-enabled ollama-persist.service 2>/dev/null | grep -q masked; then
  sudo systemctl unmask ollama-persist.service || true
fi
if [ -L "$UNIT" ] && readlink "$UNIT" | grep -q '/dev/null'; then
  sudo rm -f "$UNIT"
fi

# 2) Ensure a proper unit file exists (root user to match your test services & store perms)
sudo tee "$UNIT" >/dev/null <<UNIT
[Unit]
Description=Ollama (persistent on :11434)
After=network-online.target
Wants=network-online.target

[Service]
User=ollama
Group=ollama
SupplementaryGroups=video render
Environment=OLLAMA_MODELS=${MODELDIR}
Environment=OLLAMA_HOST=127.0.0.1:${PORT}
ExecStart=${OLLAMA_BIN} serve
Restart=always
RestartSec=2
LimitMEMLOCK=infinity
TasksMax=infinity
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
UNIT

# 3) Make sure the models dir exists & is usable
sudo mkdir -p "$MODELDIR"
sudo chown -R ollama:ollama "$MODELDIR" || true
sudo chmod 755 /FuZe /FuZe/models "$MODELDIR" || true

# 4) Don’t let the distro service collide on :11434
sudo systemctl stop ollama.service 2>/dev/null || true
sudo systemctl disable ollama.service 2>/dev/null || true

# 5) Reload units & start the persistent one
sudo systemctl daemon-reload
sudo systemctl enable --now ollama-persist.service

# 6) Sanity check
sleep 1
echo "--- listeners ---"
for p in 11434 11435 11436; do
  echo "PORT $p:"
  sudo lsof -nP -iTCP:$p -sTCP:LISTEN -FpctLn | paste -sd' ' -
done
echo "--- ping :11434 ---"
curl -fsS http://127.0.0.1:11434/api/tags >/dev/null && echo "OK /api/tags" || echo "NOT UP"

# 7) `ollama ls` should work again
ollama ls || true
