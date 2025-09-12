#!/usr/bin/env bash
# install.sh — One-shot Ollama setup with store merge and service config
# - Installs dependencies
# - Installs or upgrades Ollama (if OLLAMA_UPGRADE=1)
# - Ensures canonical model store at /FuZe/models/ollama (merges any /FuZe/ollama/models content)
# - Creates systemd override (OLLAMA_HOST=127.0.0.1:11434, OLLAMA_MODELS=/FuZe/models/ollama)
# - Enables & starts service, verifies health
#
# Usage:
#   sudo ./install.sh
#
# Optional env:
#   OLLAMA_UPGRADE=1          # run official installer even if ollama exists
#   OLLAMA_HOST=127.0.0.1:11434
#   CANON_STORE=/FuZe/models/ollama
#   ALT_STORE=/FuZe/ollama/models

set -euo pipefail

# ---------- config ----------
: "${OLLAMA_HOST:=127.0.0.1:11434}"
: "${CANON_STORE:=/FuZe/models/ollama}"
: "${ALT_STORE:=/FuZe/ollama/models}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

say()  { printf '== %s ==\n' "$*"; }
ok()   { printf '✔ %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die()  { printf '✖ %s\n' "$*" >&2; exit 1; }

# ---------- deps ----------
say "Installing dependencies"
apt-get update -y
apt-get install -y curl jq lsof gawk sed procps coreutils

# ---------- install/upgrade ollama ----------
if ! command -v ollama >/dev/null 2>&1; then
  say "Installing Ollama"
  curl -fsSL https://ollama.com/install.sh | sh
  ok "Ollama installed"
else
  if [ "${OLLAMA_UPGRADE:-0}" = "1" ]; then
    say "Upgrading Ollama"
    curl -fsSL https://ollama.com/install.sh | sh
    ok "Ollama upgraded"
  else
    ok "Ollama already present: $(ollama --version || true)"
  fi
fi

# ---------- ensure directories / symlink ----------
say "Preparing canonical store"
mkdir -p "$CANON_STORE"/{blobs,manifests}
chmod 755 /FuZe /FuZe/models "$CANON_STORE" || true

# convenience symlink /FuZe/ollama -> /FuZe/models/ollama
if [ -e /FuZe/ollama ] && [ ! -L /FuZe/ollama ]; then
  # if it's a real dir, leave it (we might be merging from inside it)
  :
elif [ ! -e /FuZe/ollama ]; then
  ln -s "$CANON_STORE" /FuZe/ollama || true
fi

# ---------- stop service (safe if not installed yet) ----------
say "Stopping Ollama service (if running)"
systemctl stop ollama 2>/dev/null || true

# ---------- merge ALT_STORE into CANON_STORE without re-download ----------
merge_dir() {
  # $1 = src dir, $2 = dst dir
  local src="$1" dst="$2"
  [ -d "$src" ] || return 0
  mkdir -p "$dst"
  local moved=0 dupes=0 kept=0 compared=0 total
  total=$(find "$src" -type f | wc -l | tr -d ' ')

  # prune obviously broken partials in src
  find "$src" -type f -name '*-partial-*' -delete 2>/dev/null || true

  local count=0
  # Use find -print0 to handle any odd names (rsync not strictly required)
  while IFS= read -r -d '' f; do
    count=$((count+1))
    local rel="${f#"$src/"}"
    local dstdir="$dst/$(dirname "$rel")"
    local dstfile="$dst/$rel"

    mkdir -p "$dstdir"
    if [ -e "$dstfile" ]; then
      # If identical, drop source; else, keep conflict (do not overwrite)
      if cmp -s "$f" "$dstfile"; then
        rm -f -- "$f"
        dupes=$((dupes+1))
      else
        kept=$((kept+1))
      fi
      compared=$((compared+1))
    else
      # Try rename first (cheap on same FS), fall back to copy then remove
      if mv -n -- "$f" "$dstfile" 2>/dev/null; then
        moved=$((moved+1))
      else
        if cp -n -- "$f" "$dstfile" 2>/dev/null; then
          rm -f -- "$f"
          moved=$((moved+1))
        else
          kept=$((kept+1))
        fi
      fi
    fi

    # lightweight progress for large stores
    if (( count % 200 == 0 )); then
      printf "   [%s] %d/%d moved=%d dupes_removed=%d kept_conflicts=%d compared=%d\r" \
        "$(basename "$dst")" "$count" "$total" "$moved" "$dupes" "$kept" "$compared"
    fi
  done < <(find "$src" -type f -print0)

  printf "   [%s] %d/%d moved=%d dupes_removed=%d kept_conflicts=%d compared=%d\n" \
    "$(basename "$dst")" "$count" "$total" "$moved" "$dupes" "$kept" "$compared"
}

if [ -d "$ALT_STORE" ] && [ "$ALT_STORE" != "$CANON_STORE" ]; then
  say "Merging alternate store into canonical"
  # merge blobs then manifests (structure differs)
  merge_dir "$ALT_STORE/blobs"     "$CANON_STORE/blobs"
  merge_dir "$ALT_STORE/manifests" "$CANON_STORE/manifests"

  # remove now-empty dirs if possible
  find "$ALT_STORE" -type d -empty -delete 2>/dev/null || true
  ok "Store merge complete"
else
  ok "No alternate store to merge"
fi

# ---------- ownership fix (service user may be 'ollama') ----------
SERVICE_USER="$(systemctl show -p User ollama 2>/dev/null | cut -d= -f2 || true)"
if [ -z "$SERVICE_USER" ] || [ "$SERVICE_USER" = "root" ]; then
  SERVICE_USER="root"
fi
if id "$SERVICE_USER" >/dev/null 2>&1; then
  chown -R "$SERVICE_USER:$SERVICE_USER" "$CANON_STORE" || true
fi

# ---------- systemd override ----------
say "Writing systemd override"
mkdir -p /etc/systemd/system/ollama.service.d
cat >/etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment=OLLAMA_MODELS=${CANON_STORE}
Environment=OLLAMA_HOST=${OLLAMA_HOST}
Restart=always
RestartSec=2s
EOF

systemctl daemon-reload

# ---------- enable & start ----------
say "Enabling + starting service"
systemctl enable --now ollama

# ---------- health checks ----------
say "Health checks"
sleep 1
if curl -fsS "http://${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
  ok "API reachable at ${OLLAMA_HOST}"
else
  warn "API not reachable yet at ${OLLAMA_HOST}"
fi

ollama --version || true
ollama list || true

echo
ok "Install complete"
echo "   Canonical store : ${CANON_STORE}"
echo "   Service host    : ${OLLAMA_HOST}"
echo "   Upgrade on rerun: OLLAMA_UPGRADE=1 sudo ./install.sh"

