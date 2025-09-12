#!/usr/bin/env bash
# install.sh — Install Ollama + repair/migrate store to /FuZe/models/ollama, safely.
# - Installs deps & Ollama (if missing)
# - Stops service during migration/cleanup to avoid partial blob errors
# - Sets /FuZe/models/ollama as the canonical model store via systemd drop-in
# - Repairs directory layout and removes stale *-partial-* files
# - Preserves existing models (no re-download)

set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
as_root() { if [ "$(id -u)" -ne 0 ]; then echo "Please run as root (sudo)." >&2; exit 1; fi; }

as_root
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y curl jq lsof gawk sed procps coreutils rsync

# Install Ollama if missing
if ! command -v ollama >/dev/null 2>&1; then
  echo "== Installing Ollama =="
  curl -fsSL https://ollama.com/install.sh | sh
else
  echo "== Ollama already installed: $(ollama --version || true)"
fi

# Paths
TARGET_STORE="/FuZe/models/ollama"
LEGACY_CANDIDATE_1="/FuZe/ollama/models"   # seen in your logs
LEGACY_CANDIDATE_2="/FuZe/ollama"          # old symlink/dir some setups use
DROPIN_DIR="/etc/systemd/system/ollama.service.d"
DROPIN_FILE="${DROPIN_DIR}/10-fuze-store.conf"

# Ensure canonical dirs exist
mkdir -p /FuZe /FuZe/models "$TARGET_STORE"
chmod 755 /FuZe /FuZe/models || true

# If there is a convenience link, make it point at the canonical store
if [ -e /FuZe/ollama ] || [ -L /FuZe/ollama ]; then
  rm -rf /FuZe/ollama
fi
ln -s "$TARGET_STORE" /FuZe/ollama || true

# Determine service user (empty means root)
SERVICE_USER="$(systemctl show ollama.service -p User | sed -n 's/^User=//p')"
if [ -z "$SERVICE_USER" ]; then SERVICE_USER="root"; fi

echo "== Stopping ollama.service (if running) =="
systemctl stop ollama.service 2>/dev/null || true

# Migrate from legacy locations if present
migrate_dir() {
  local src="$1"
  [ -d "$src" ] || return 0
  echo "== Migrating from: $src -> $TARGET_STORE =="
  # rsync without carrying over problematic group/perms; fix ownership after
  rsync -aHAX --numeric-ids --inplace --partial --mkpath \
        --no-perms --no-group \
        --info=stats1,progress2 \
        "$src"/ "$TARGET_STORE"/ || true
}
migrate_dir "$LEGACY_CANDIDATE_1"
# If /FuZe/ollama was a real directory (not the new symlink), migrate that too
if [ -d "$LEGACY_CANDIDATE_2" ] && [ ! -L "$LEGACY_CANDIDATE_2" ]; then
  migrate_dir "$LEGACY_CANDIDATE_2"
fi

# Ensure mandatory subdirs exist
mkdir -p "$TARGET_STORE/blobs" "$TARGET_STORE/manifests"
# Clean left-over partials that confuse pulls
find "$TARGET_STORE" -type f -name '*-partial-*' -print -delete || true

# Set ownership for the service user
if id "$SERVICE_USER" >/dev/null 2>&1; then
  chown -R "$SERVICE_USER":"$SERVICE_USER" "$TARGET_STORE" || true
fi

# Systemd drop-in so the service ALWAYS uses the canonical store
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN_FILE" <<EOF
[Service]
Environment=OLLAMA_MODELS=$TARGET_STORE
# (optional) pin bind address/port; default is 127.0.0.1:11434 already
# Environment=OLLAMA_HOST=127.0.0.1:11434
EOF

systemctl daemon-reload

echo "== Enabling & starting ollama.service =="
systemctl enable --now ollama.service

# Quick sanity: verify service and env
sleep 1
if ! curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  echo "WARN: Ollama API on :11434 not reachable yet. Waiting up to 30s..."
  for i in $(seq 1 30); do
    if curl -fsS --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then break; fi
    sleep 1
  done
fi

# Print final env and store contents summary
echo
echo "== ollama.service environment (excerpt) =="
systemctl show ollama.service -p Environment | sed 's/^Environment=//'
echo
echo "== Store check =="
echo "Store: $TARGET_STORE"
echo "Blobs: $(find "$TARGET_STORE/blobs" -maxdepth 1 -type f 2>/dev/null | wc -l) files"
echo "Tags : $(OLLAMA_HOST=http://127.0.0.1:11434 ollama list 2>/dev/null | awk 'NR==1 && $1=="NAME"{next} {print $1}' | wc -l)"

echo
echo "✔ Ollama install & store migration complete."
echo "  Canonical store : $TARGET_STORE"
echo "  Service user    : $SERVICE_USER"
echo "  Version         : $(ollama --version || echo unknown)"

