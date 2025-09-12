replace-block \
  /home/fuze/GitHub/FuZeCORE.ai/fuze-box/stack/ollama/ollama-benchmark.sh \
  '^\s*if \[ -s "\$\{SUMMARY_FILE\}\.raw" \]; then$' \
  '^\s*fi\s*$' \
  /home/fuze/GitHub/FuZeCORE.ai/utils/patches/ollama_success_check.block \
  .bak

