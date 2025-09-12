#!/usr/bin/env bash
# install.sh — Clean install/upgrade of Ollama with ONLY the stock ollama.service on :11434.
#               Stops ALL ollama* services, removes custom units, restarts stock service as ollama:ollama.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

# ---- Packages ----------------------------------------------------------------
apt-get update -y
apt-get install -y curl jq lsof gawk sed procps coreutils rsync

# ---- Install or upgrade Ollama ----------------------------------------------
if ! command -v ollama >/dev/null 2>&1; then
  echo "== Installing Ollama =="
  curl -fsSL https://ollama.com/install.sh | sh
else
  echo "== Upgrading Ollama (if newer available) =="
  OLLAMA_UPGRADE=1 curl -fsSL https://ollama.com/install.sh | sh || true
fi

# ---- Ensure ollama user/groups & store ownership ----------------------------
if ! id -u ollama >/dev/null 2>&1; then
  useradd -r -s /usr/sbin/nologin -m ollama
fi
for g in video render; do
  getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" ollama || true
done

CANON=/FuZe/models/ollama
mkdir -p /FuZe /FuZe/models "$CANON"
chmod 755 /FuZe /FuZe/models "$CANON"
chown -R ollama:ollama "$CANON"
[ -e /FuZe/ollama ] || ln -s "$CANON" /FuZe/ollama || true

# ---- STOP everything named ollama*.service first ----------------------------
echo "== Stopping ALL ollama* services =="
# Unmask before stop/disable to avoid surprises
systemctl list-unit-files | awk '/^ollama.*\.service/ {print $1}' | while read -r u; do
  systemctl unmask "$u" 2>/dev/null || true
  systemctl stop "$u" 2>/dev/null || true
  systemctl disable "$u" 2>/dev/null || true
  systemctl reset-failed "$u" 2>/dev/null || true
done

# ---- Remove custom/legacy units (keep ONLY stock ollama.service) ------------
echo "== Removing custom/legacy ollama units =="
# Known custom patterns: ollama-*.service, ollama-test-*.service, ollama-persist.service
find /etc/systemd/system -maxdepth 1 -type f -name 'ollama-*.service' -not -name 'ollama.service' -print -delete || true
rm -f /etc/systemd/system/ollama-test-a.service /etc/systemd/system/ollama-test-b.service /etc/systemd/system/ollama-persist.service 2>/dev/null || true

# Clean any dangling wants/aliases symlinks that point to removed units
find /etc/systemd/system -type l -lname '*ollama-*service' -not -lname '*ollama.service' -print -delete || true

# ---- Kill stray daemons on 11435/11436 (TEST ports) -------------------------
pkill -f "/usr/local/bin/ollama serve -p 11435" 2>/dev/null || true
pkill -f "/usr/local/bin/ollama serve -p 11436" 2>/dev/null || true

# ---- Enforce stock ollama.service to run as ollama with our store -----------
mkdir -p /etc/systemd/system/ollama.service.d
cat >/etc/systemd/system/ollama.service.d/override.conf <<'DROPIN'
[Service]
User=ollama
Group=ollama
SupplementaryGroups=video render
Environment=OLLAMA_MODELS=/FuZe/models/ollama
# ExecStart provided by package; defaults to port 11434
DROPIN

# ---- Reload daemon and start ONLY stock service ------------------------------
systemctl daemon-reload
systemctl unmask ollama.service 2>/dev/null || true
systemctl enable --now ollama.service

# ---- Sanity: listeners & ping ------------------------------------------------
echo
echo "=== Listeners ==="
for p in 11434 11435 11436; do
  echo "PORT $p:"
  lsof -nP -iTCP:$p -sTCP:LISTEN -FpctLn | paste -sd' ' - || true
done

echo
echo "=== Ping :11434 ==="
if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null; then
  echo "OK /api/tags"
else
  echo "NOT UP — check:"
  echo "  sudo systemctl status ollama --no-pager -l"
  echo "  sudo journalctl -u ollama -e --no-pager"
fi

echo
echo "✔ Ollama ready (stock service ONLY)"
echo "   Store   : $CANON (owner: ollama:ollama)"
echo "   Version : $(ollama --version || echo 'unknown')"

