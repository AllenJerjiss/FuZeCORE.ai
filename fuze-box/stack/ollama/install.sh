#!/usr/bin/env bash
# install.sh — Clean install/upgrade of Ollama with ONLY the stock ollama.service on :11434
# - Installs/upgrades Ollama
# - Ensures /FuZe/models/ollama owned by ollama:ollama
# - Stops & removes ALL custom/legacy ollama*.service units (keeps only ollama.service)
# - Kills stray "ollama serve" daemons (e.g., on 11435/11436)
# - Starts stock ollama.service as user ollama, store at /FuZe/models/ollama
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

# ---- Stop ALL ollama* services (stock & custom) -----------------------------
echo "== Stopping ALL ollama* services =="
systemctl list-unit-files | awk '/^ollama.*\.service/ {print $1}' | while read -r u; do
  systemctl unmask "$u" 2>/dev/null || true
  systemctl stop "$u" 2>/dev/null || true
  systemctl disable "$u" 2>/dev/null || true
  systemctl reset-failed "$u" 2>/dev/null || true
done

# ---- REMOVE custom/legacy units everywhere (keep ONLY stock 'ollama.service')
echo "== Removing custom/legacy ollama units =="
# List all systemd unit files that start with 'ollama' EXCEPT 'ollama.service'
units_to_remove="$(systemctl list-unit-files --type=service | \
  awk '/^ollama.*\.service/ && $1!="ollama.service" {print $1}' || true)"

# Common unit dirs to purge from:
UNIT_DIRS="/etc/systemd/system /lib/systemd/system /usr/lib/systemd/system"

# Remove units and their drop-ins/symlinks
for u in $units_to_remove; do
  # delete unit files
  for d in $UNIT_DIRS; do
    rm -f "$d/$u" 2>/dev/null || true
    rm -rf "$d/${u}.d" 2>/dev/null || true
  done
  # delete wants/aliases symlinks that point to that unit
  find /etc/systemd/system -type l -lname "*$u" -print -delete 2>/dev/null || true
done

# Also explicitly remove commonly seen customs
rm -f /etc/systemd/system/ollama-persist.service \
      /etc/systemd/system/ollama-test-a.service \
      /etc/systemd/system/ollama-test-b.service 2>/dev/null || true
rm -rf /etc/systemd/system/ollama-persist.service.d \
       /etc/systemd/system/ollama-test-a.service.d 2>/dev/null || true

# Catch any GPU-bound custom units like ollama-5090.service, ollama-3090ti.service
find /etc/systemd/system -maxdepth 1 -type f -name 'ollama-*.service' -print -delete 2>/dev/null || true
find /etc/systemd/system -maxdepth 1 -type d -name 'ollama-*.service.d' -print -exec rm -rf {} + 2>/dev/null || true
find /etc/systemd/system -type l -name 'ollama-*.service' -print -delete 2>/dev/null || true

# ---- Kill ALL stray "ollama serve" daemons (will relaunch stock fresh) ------
echo "== Killing stray ollama daemons =="
main_pid="$(systemctl show -p MainPID --value ollama.service 2>/dev/null || true)"
pgrep -f "/usr/local/bin/ollama serve" >/dev/null 2>&1 && \
  pgrep -f "/usr/local/bin/ollama serve" | while read -r pid; do
    if [ -n "${main_pid:-}" ] && [ "$pid" = "$main_pid" ]; then
      continue
    fi
    kill -TERM "$pid" 2>/dev/null || true
  done
# Wait a moment, then hard-kill anything left
sleep 1
pgrep -f "/usr/local/bin/ollama serve" >/dev/null 2>&1 && \
  pgrep -f "/usr/local/bin/ollama serve" | while read -r pid; do
    if [ -n "${main_pid:-}" ] && [ "$pid" = "$main_pid" ]; then
      continue
    fi
    kill -KILL "$pid" 2>/dev/null || true
  done

# ---- Enforce stock ollama.service to run as ollama with our store -----------
echo "== Configuring stock ollama.service =="
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

# ---- Final sweep: no listeners should remain on 11435/11436 -----------------
for p in 11435 11436; do
  pid="$(lsof -nP -iTCP:$p -sTCP:LISTEN -t 2>/dev/null || true)"
  [ -n "${pid:-}" ] && kill -TERM "$pid" 2>/dev/null || true
done

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
echo "✔ Ollama ready (ONLY stock service is active)"
echo "   Store   : $CANON (owner: ollama:ollama)"
echo "   Version : $(ollama --version || echo 'unknown')"

