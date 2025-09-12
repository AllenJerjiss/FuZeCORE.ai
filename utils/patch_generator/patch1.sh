mkdir -p /home/fuze/GitHub/FuZeCORE.ai/fuze-box/stack/patches

cat >/home/fuze/GitHub/FuZeCORE.ai/utils/patches/ollama_success_check.block <<'BLOCK'
# Any optimized rows with tokens_per_sec > 0 ?
if awk -F',' 'NR>1 && $6 ~ /^optimized$/ && $12+0>0 {exit 0} END{exit 1}' "$CSV_FILE"; then
  # Show best per endpoint/model if we computed any in SUMMARY_FILE.raw
  if [ -s "${SUMMARY_FILE}.raw" ]; then
    echo "Best optimized per (endpoint, model):"
    column -t -s',' "${SUMMARY_FILE}.raw" 2>/dev/null || cat "${SUMMARY_FILE}.raw"
  else
    echo "Optimized variants ran (see CSV), but per-(endpoint,model) best list is empty."
  fi
else
  echo "No optimized variants succeeded."
fi
BLOCK

