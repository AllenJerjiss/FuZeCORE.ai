#!/usr/bin/env bash
# install.sh — Install/upgrade Ollama, set store, create ollama-run-as-user services
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

# ---- Packages
apt-get update -y
apt-get install -y curl jq lsof gawk sed procps coreutils rsync

# ---- Install or upgrade Ollama
if ! command -v ollama >/dev/null 2>&1; then
  echo "== Installing Ollama =="
  curl -fsSL https://ollama.com/install.sh | sh
else
  echo "== Upgrading Ollama =="
  curl -fsSL https://ollama.com/install.sh | OLLAMA_UPGRADE=1 sh || true
fi

# ---- Ensure user/group & GPU access
# Ollama installer usually creates the 'ollama' user, but ensure it and groups.
if ! id -u ollama >/dev/null 2>&1; then
  useradd -r -s /usr/sbin/nologin -m ollama
fi
# Make sure the user can access GPUs
for g in video render; do
  getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" ollama || true
done

# ---- Model store
CANON=/FuZe/models/ollama
mkdir -p "$CANON"
# allow traverse on parents; and give dir ownership to ollama
mkdir -p /FuZe /FuZe/models
chmod 755 /FuZe /FuZe/models
chown -R ollama:ollama "$CANON"
chmod 755 "$CANON"

# Handy symlink (optional)
[ -e /FuZe/ollama ] || ln -s "$CANON" /FuZe/ollama || true

# ---- Disable distro's default service to avoid port collisions on :11434
systemctl stop    ollama.service 2>/dev/null || true
systemctl disable ollama.service 2>/dev/null || true
systemctl reset-failed ollama.service 2>/dev/null || true

# ---- (Re)create run-as-ollama services
cat >/etc/systemd/system/ollama-persist.service <<'UNIT'
[Unit]
Description=Ollama (persistent on :11434)
After=network-online.target
Wants=network-online.target

[Service]
User=ollama
Group=ollama
# In case your distro uses device groups for GPUs
SupplementaryGroups=video render
Environment=OLLAMA_MODELS=/FuZe/models/ollama
ExecStart=/usr/local/bin/ollama serve -p 11434
Restart=always
RestartSec=2
LimitMEMLOCK=infinity
TasksMax=infinity
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/ollama-test-a.service <<'UNIT'
[Unit]
Description=Ollama (TEST A on :11435)
After=network-online.target
Wants=network-online.target

[Service]
User=ollama
Group=ollama
SupplementaryGroups=video render
Environment=OLLAMA_MODELS=/FuZe/models/ollama
ExecStart=/usr/local/bin/ollama serve -p 11435
Restart=always
RestartSec=2
LimitMEMLOCK=infinity
TasksMax=infinity
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/ollama-test-b.service <<'UNIT'
[Unit]
Description=Ollama (TEST B on :11436)
After=network-online.target
Wants=network-online.target

[Service]
User=ollama
Group=ollama
SupplementaryGroups=video render
Environment=OLLAMA_MODELS=/FuZe/models/ollama
ExecStart=/usr/local/bin/ollama serve -p 11436
Restart=always
RestartSec=2
LimitMEMLOCK=infinity
TasksMax=infinity
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
UNIT

# ---- Reload and bring them up
systemctl daemon-reload
systemctl enable --now ollama-persist.service
systemctl enable --now ollama-test-a.service
systemctl enable --now ollama-test-b.service

# ---- Sanity checks
sleep 1
echo
echo "=== Listeners ==="
for p in 11434 11435 11436; do
  echo "PORT $p:"
  lsof -nP -iTCP:$p -sTCP:LISTEN -FpctLn | paste -sd' ' - || true
done
echo
echo "=== Ping :11434 ==="
curl -fsS http://127.0.0.1:11434/api/tags >/dev/null && echo "OK /api/tags" || echo "NOT UP"

echo
echo "✔ Ollama ready (run-as user: ollama)"
echo "   Store     : $CANON (owner: ollama:ollama)"
echo "   Version   : $(ollama --version || echo 'unknown')"

