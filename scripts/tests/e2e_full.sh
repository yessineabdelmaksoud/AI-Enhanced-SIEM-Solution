cat > ~/soc-ai-lab/scripts/tests/e2e_full.sh << 'EOF'
#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS=()
PASS=0
FAIL=0
START=$(date +%s)

for S in S1 S2 S3 S4 S5; do
  echo "==================== $S ===================="
  OUT=$("$SCRIPT_DIR/e2e_run_scenario.sh" "$S" 2>&1)
  RC=$?
  echo "$OUT"
  JSON=$(echo "$OUT" | grep -E '^\{' | tail -1 || echo '{}')
  RESULTS+=("$JSON")
  if [ "$RC" -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
done

END=$(date +%s); DUR=$((END-START))

echo ""
echo "==================== SUMMARY ===================="
printf '%s\n' "${RESULTS[@]}" | jq -s '
  (map(.latencies_ms.explain?, .latencies_ms.investigate?, .latencies_ms.remediate?)
    | map(select(. != null and . > 0)) | sort) as $lat
  | {
      scenarios: length,
      total_validated: (map(.validated_count // 0) | add),
      max_possible: (length * 3),
      latency_count: ($lat | length),
      latency_min_ms: ($lat | min),
      latency_mean_ms: (if ($lat|length)>0 then (($lat|add)/($lat|length)|floor) else 0 end),
      latency_max_ms: ($lat | max),
      latency_p95_ms: (if ($lat|length)>0 then $lat[(((($lat|length)|tonumber)*0.95)|ceil)-1] else 0 end),
      latencies_sorted_ms: $lat
    }'

echo ""
echo "Scenarios OK: $PASS / 5   |   KO: $FAIL"
echo "Durée totale: ${DUR}s ($((DUR/60))m$((DUR%60))s)"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
EOF
chmod +x ~/soc-ai-lab/scripts/tests/e2e_full.sh