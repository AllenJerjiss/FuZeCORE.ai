# >>> TOP10 (replacement)
echo "== Top-10 overall by tokens/sec =="
if [ -s "$CSV_FILE" ]; then
  tail -n +2 "$CSV_FILE" | sort -t',' -k12,12gr | head -n10 \
    | awk -F',' '{printf "  %-2s %-18s %-28s %-14s %6.2f tok/s  (%s %s ngpu=%s)\n",$4,$5,$6,$13,$12,$1,$2,$8}'
else
  echo "No CSV rows."
fi
# >>> END TOP10
