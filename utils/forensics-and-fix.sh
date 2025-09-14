#!/usr/bin/env bash
set -euo pipefail

# Forensics + auto-fix wrapper for FuZeCORE.ai benchmarks summary
# - Produces a timestamped bundle under .forensics/
# - Anchors a "pre-force" baseline if available
# - Runs summarize-benchmarks.sh -> raw + fixed outputs
# - Fixed output: dedup table headers, aligned columns, dynamic widths (incl. variant)

# ---- config ----
REPO_ROOT="${1:-$(pwd)}"
SUMMARIZER="factory/LLM/refinery/stack/common/summarize-benchmarks.sh"
CSV_PATH="factory/LLM/refinery/benchmarks.csv"
ENV_PATH="factory/LLM/refinery/stack/llama.cpp/models.env"
COMMON_DIR="factory/LLM/refinery/stack/common"

ts() { date +"%Y%m%d_%H%M%S"; }
BUNDLE_DIR="$REPO_ROOT/.forensics/$(ts)"
OUT_DIR="$BUNDLE_DIR/outputs"
GIT_DIR="$BUNDLE_DIR/git"
DIFF_DIR="$BUNDLE_DIR/diffs"
FILES_DIR="$BUNDLE_DIR/files"

mkdir -p "$OUT_DIR" "$GIT_DIR" "$DIFF_DIR" "$FILES_DIR"

cd "$REPO_ROOT"

# ---- sanity checks ----
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: $REPO_ROOT is not a git repo." >&2
  exit 1
fi

echo "== Forensics target ==" | tee "$BUNDLE_DIR/README.txt"
echo "Repo: $(git rev-parse --show-toplevel)" | tee -a "$BUNDLE_DIR/README.txt"
echo "Head: $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)" | tee -a "$BUNDLE_DIR/README.txt"
echo "Time: $(date -Is)" | tee -a "$BUNDLE_DIR/README.txt"
echo

# ---- system/host snapshot (minimal) ----
{
  echo "uname -a:"; uname -a
  echo
  echo "hostnamectl (if available):"; command -v hostnamectl && hostnamectl || true
} > "$BUNDLE_DIR/host.txt" 2>&1 || true

# ---- git snapshot ----
git fetch --all --prune --tags >/dev/null 2>&1 || true

{
  echo "== git status -sb =="; git status -sb
  echo; echo "== branch -vv =="; git branch -vv
  echo; echo "== remote -v =="; git remote -v
  echo; echo "== log --oneline --graph -n 50 =="; git log --oneline --graph --decorate -n 50
} > "$GIT_DIR/status.txt"

{
  echo "== reflog HEAD (last 30) =="; git reflog -n 30 --date=iso
  echo; echo "== reflog origin/main (last 30) =="; git reflog show origin/main -n 30 --date=iso || true
} > "$GIT_DIR/reflogs.txt"

# detect merge/rebase in progress
{
  echo "rebase-apply: $( [ -d .git/rebase-apply ] && echo yes || echo no )"
  echo "rebase-merge: $( [ -d .git/rebase-merge ] && echo yes || echo no )"
  echo "MERGE_HEAD:   $( [ -f .git/MERGE_HEAD ] && echo yes || echo no )"
  echo; echo "Unmerged files:"
  git diff --name-only --diff-filter=U || true
} > "$GIT_DIR/integration_state.txt"

# ---- baseline selection (pre-force if available) ----
BASELINE=""
if git rev-parse --verify -q origin/main@{1} >/dev/null; then
  BASELINE="origin/main@{1}"
else
  # fallback to merge-base of current HEAD and remote tip
  if git rev-parse --verify -q origin/main >/dev/null; then
    BASELINE="$(git merge-base HEAD origin/main)"
  else
    BASELINE="$(git merge-base HEAD @{u} 2>/dev/null || echo "")"
  fi
fi

echo "Baseline chosen: ${BASELINE:-<none available>}" | tee -a "$BUNDLE_DIR/README.txt"
echo "${BASELINE:-none}" > "$GIT_DIR/baseline.txt" || true

# ---- file snapshots ----
for p in "$SUMMARIZER" "$CSV_PATH" "$ENV_PATH"; do
  if [ -f "$p" ]; then
    mkdir -p "$(dirname "$FILES_DIR/$p")"
    cp "$p" "$FILES_DIR/$p"
  fi
done
if [ -d "$COMMON_DIR" ]; then
  tar -C "$REPO_ROOT" -czf "$FILES_DIR/common-dir.tar.gz" "$COMMON_DIR" || true
fi

# ---- diffs vs baseline ----
if [ -n "$BASELINE" ]; then
  for p in "$SUMMARIZER" "$CSV_PATH" "$ENV_PATH" "$COMMON_DIR"; do
    if [ -e "$p" ]; then
      out="$DIFF_DIR/$(echo "$p" | tr '/' '_').diff"
      git diff -U3 --color=always "$BASELINE"..HEAD -- "$p" > "$out" || true
    fi
  done
fi

# ---- path-scoped history ----
{
  echo "== summarize-benchmarks.sh recent changes =="; git log -n 20 --oneline -- "$SUMMARIZER" || true
  echo; echo "== common/ scripts recent changes =="; git log -n 20 --oneline -- "$COMMON_DIR" || true
  echo; echo "== CSV recent changes =="; git log -n 10 --oneline -- "$CSV_PATH" || true
  echo; echo "== models.env recent changes =="; git log -n 10 --oneline -- "$ENV_PATH" || true
} > "$GIT_DIR/path_logs.txt"

# ---- run summarizer (raw) ----
RAW_OUT="$OUT_DIR/summary_raw.txt"
FIX_OUT="$OUT_DIR/summary_fixed.txt"
if [ -x "$SUMMARIZER" ]; then
  echo "Running $SUMMARIZER ..."
  "$SUMMARIZER" > "$RAW_OUT" 2> "$OUT_DIR/summarizer.stderr.txt" || true
else
  echo "WARN: $SUMMARIZER not executable or not found; skipping run" | tee -a "$BUNDLE_DIR/README.txt"
fi

# ---- post-processor: dedup headers + align columns with dynamic widths ----
# This rewrites each contiguous '|' table block:
# - keeps a single header block (border/header/border) per section
# - pads all columns to the max width seen in that block (data-driven)
# - ensures 'variant' column expands with real max length in the block
cat > "$OUT_DIR/fix_tables.awk" <<'AWK'
function trim(s){ sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
function repeat(ch, n,   r,i){ r=""; for(i=0;i<n;i++) r=r ch; return r }
function print_table(rows, nrows,   i,j,ncols, w, hdr_idx, is_sep, hdr_seen, row, coltxt) {
  if (nrows==0) return
  # Identify header block (first three lines if they look like border/name/border)
  hdr_idx = 0
  if (nrows>=3 && rows[1] ~ /^\|[-: ]+\|$/ && rows[2] ~ /^\|[[:space:]]*timestamp[[:space:]]*\|/ && rows[3] ~ /^\|[-: ]+\|$/) {
    hdr_idx = 2  # header text row
  }
  # Parse all rows into fields
  split("", cols); split("", widths)
  ncols = 0
  # First pass: compute widths from DATA rows (skip duplicate header blocks)
  for (i=1;i<=nrows;i++) {
    row = rows[i]
    if (row ~ /^\|[-: ]+\|$/) continue # borders don't affect widths
    if (i==2 && hdr_idx==2) continue   # skip header text for widths
    # split by '|'
    nf = split(row, parts, /\|/)
    # parts[1] and parts[nf] are empty around edges; normalize columns (2..nf-1)
    for (j=2;j<=nf-1;j++) {
      coltxt = trim(parts[j])
      if (j-1 > ncols) ncols = j-1
      len = length(coltxt)
      if (len > widths[j-1]) widths[j-1] = len
      data[i, j-1] = coltxt
    }
  }
  # Second pass: print header (once), then data rows aligned
  # Build border based on widths
  border="|"
  for (j=1;j<=ncols;j++) border = border repeat("-", widths[j] + 2) "|"
  print border
  # Header row: if we detected one, use its cells; else synthesize from second line if present
  if (hdr_idx==2) {
    nf = split(rows[2], parts, /\|/)
    out="|"
    for (j=2;j<=nf-1;j++) {
      coltxt = trim(parts[j])
      pad = widths[j-1] - length(coltxt)
      out = out " " coltxt repeat(" ", pad) " |"
    }
    print out
  } else {
    # No header detected: synthesize generic numbered headers
    out="|"
    for (j=1;j<=ncols;j++) {
      coltxt = "col" j
      pad = widths[j] - length(coltxt)
      out = out " " coltxt repeat(" ", pad) " |"
    }
    print out
  }
  print border
  # Now print only data lines (skip any duplicate header lines encountered)
  for (i=1;i<=nrows;i++) {
    row = rows[i]
    if (row ~ /^\|[-: ]+\|$/) continue
    if (i==2 && hdr_idx==2) continue
    nf = split(row, parts, /\|/)
    out="|"
    for (j=2;j<=nf-1;j++) {
      coltxt = trim(parts[j])
      pad = widths[j-1] - length(coltxt)
      out = out " " coltxt repeat(" ", pad) " |"
    }
    print out
  }
}
# Main: accumulate contiguous '|' blocks; any other lines flush the current table
{
  if ($0 ~ /^\|/) {
    tbl[++nrows] = $0
    pending=1
  } else {
    if (pending) { print_table(tbl, nrows); delete tbl; nrows=0; pending=0 }
    print $0
  }
}
END{
  if (pending) { print_table(tbl, nrows) }
}
AWK

if [ -f "$RAW_OUT" ]; then
  awk -f "$OUT_DIR/fix_tables.awk" "$RAW_OUT" > "$FIX_OUT" || true
fi

# ---- pack the bundle ----
TARBALL="$BUNDLE_DIR/forensics_bundle.tgz"
tar -C "$BUNDLE_DIR" -czf "$TARBALL" . >/dev/null 2>&1 || true

echo
echo "Forensics bundle: $TARBALL"
if [ -f "$FIX_OUT" ]; then
  echo "Raw summary:      $RAW_OUT"
  echo "Fixed summary:    $FIX_OUT"
fi
echo "Done."

