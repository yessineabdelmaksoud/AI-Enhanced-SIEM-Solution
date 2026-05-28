cat > ~/soc-ai-lab/scripts/tests/e2e_run_scenario.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

ES_HOST="https://10.110.188.110:9200"
ES_USER="elastic"
ES_PASS="SocSiem2024!"
CA="$HOME/soc-ai-lab/certs/ca.crt"
API="http://localhost:8000"
ENDPOINT="10.110.188.114"
POLL_INTERVAL=5
POLL_TIMEOUT=60

SCENARIO="${1:-}"
[ -z "$SCENARIO" ] && { echo "Usage: $0 <S1|S2|S3|S4|S5>" >&2; exit 2; }

es_query() {
  curl -sk --cacert "$CA" -u "$ES_USER:$ES_PASS" \
    "$ES_HOST/$1/_search" -H 'Content-Type: application/json' -d "$2"
}

enrich() { curl -s -X POST "$API/enrich/$1/$2"; }

poll_alert() {
  local index="$1" query="$2" elapsed=0 resp hits id
  while [ "$elapsed" -lt "$POLL_TIMEOUT" ]; do
    resp=$(es_query "$index" "$query")
    hits=$(echo "$resp" | jq -r '.hits.total.value // 0')
    if [ "$hits" -gt 0 ]; then
      echo "$resp" | jq -r '.hits.hits[0]._id'
      return 0
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
  return 1
}

TIME_FILTER='{"range":{"@timestamp":{"gte":"now-3m"}}}'
case "$SCENARIO" in
  S1)
    DESC="SSH brute force"
    SIM_CMD="hydra -l root -P /tmp/wordlist.txt -t 4 -f ssh://$ENDPOINT"
    INDEX="wazuh-alerts-*"
    QUERY='{"size":1,"query":{"bool":{"must":[{"terms":{"wazuh.rule_id":["5763","5712","5710","5716"]}}],"filter":['"$TIME_FILTER"']}},"sort":[{"@timestamp":{"order":"desc"}}]}'
    ;;
  S2)
    DESC="Port scan"
    SIM_CMD="sudo nmap -sS -p 1-1000 -T4 $ENDPOINT"
    INDEX="suricata-eve-*"
    QUERY='{"size":1,"query":{"bool":{"must":[{"term":{"event_type":"alert"}},{"term":{"alert.signature_id":9000002}}],"filter":['"$TIME_FILTER"']}},"sort":[{"@timestamp":{"order":"desc"}}]}'
    ;;
  S3)
    DESC="FIM /etc/passwd"
    SIM_CMD="ssh root@$ENDPOINT 'echo \"fimtest:x:9999:9999::/tmp:/usr/sbin/nologin\" >> /etc/passwd; sleep 1; sed -i \"/^fimtest:/d\" /etc/passwd'"
    INDEX="wazuh-alerts-*"
    QUERY='{"size":1,"query":{"bool":{"must":[{"terms":{"wazuh.rule_id":["550","553","554"]}}],"filter":['"$TIME_FILTER"']}},"sort":[{"@timestamp":{"order":"desc"}}]}'
    ;;
  S4)
    DESC="ICMP flood"
    SIM_CMD="sudo ping -f -c 200 $ENDPOINT"
    INDEX="suricata-eve-*"
    QUERY='{"size":1,"query":{"bool":{"must":[{"term":{"event_type":"alert"}},{"term":{"alert.signature_id":9000003}}],"filter":['"$TIME_FILTER"']}},"sort":[{"@timestamp":{"order":"desc"}}]}'
    ;;
  S5)
    DESC="Suspicious User-Agent"
    SIM_CMD="curl -s -A 'EvilScanner/1.0' http://$ENDPOINT/ -m 5"
    INDEX="suricata-eve-*"
    QUERY='{"size":1,"query":{"bool":{"must":[{"term":{"event_type":"alert"}},{"term":{"alert.signature_id":9000004}}],"filter":['"$TIME_FILTER"']}},"sort":[{"@timestamp":{"order":"desc"}}]}'
    ;;
  *) echo "Unknown scenario: $SCENARIO" >&2; exit 2 ;;
esac

echo "[*] $SCENARIO — $DESC" >&2
echo "[*] Simulation..." >&2
eval "$SIM_CMD" >/dev/null 2>&1 || true

echo "[*] Polling ES (max ${POLL_TIMEOUT}s)..." >&2
if ! ALERT_ID=$(poll_alert "$INDEX" "$QUERY"); then
  echo "[FAIL] $SCENARIO: aucune alerte détectée" >&2
  jq -nc --arg s "$SCENARIO" '{scenario:$s, alert_id:null, validated_count:0, error:"no_alert_detected"}'
  exit 1
fi
echo "[*] Alerte: $ALERT_ID" >&2

EX=$(enrich "$ALERT_ID" explain)
EX_VALID=$(echo "$EX" | jq -r '.validated // false')
EX_LEN=$(echo "$EX" | jq -r '(.response.summary // "") | length')
EX_LAT=$(echo "$EX" | jq -r '.latency_ms // 0')
EX_ID=$(echo "$EX" | jq -r '.enrichment_id // ""')

IN=$(enrich "$ALERT_ID" investigate)
IN_VALID=$(echo "$IN" | jq -r '.validated // false')
IN_LAT=$(echo "$IN" | jq -r '.latency_ms // 0')
IN_ID=$(echo "$IN" | jq -r '.enrichment_id // ""')

RE=$(enrich "$ALERT_ID" remediate)
RE_VALID=$(echo "$RE" | jq -r '.validated // false')
RE_LAT=$(echo "$RE" | jq -r '.latency_ms // 0')
RE_ID=$(echo "$RE" | jq -r '.enrichment_id // ""')

VC=0
[ "$EX_VALID" = "true" ] && VC=$((VC+1))
[ "$IN_VALID" = "true" ] && VC=$((VC+1))
[ "$RE_VALID" = "true" ] && VC=$((VC+1))

jq -nc \
  --arg scenario "$SCENARIO" --arg alert_id "$ALERT_ID" \
  --arg ex_id "$EX_ID" --arg in_id "$IN_ID" --arg re_id "$RE_ID" \
  --argjson ex_lat "$EX_LAT" --argjson in_lat "$IN_LAT" --argjson re_lat "$RE_LAT" \
  --argjson vc "$VC" --argjson ex_len "$EX_LEN" \
  '{scenario:$scenario, alert_id:$alert_id,
    enrichment_ids:{explain:$ex_id, investigate:$in_id, remediate:$re_id},
    latencies_ms:{explain:$ex_lat, investigate:$in_lat, remediate:$re_lat},
    validated_count:$vc, explain_summary_len:$ex_len}'

if [ "$VC" -eq 3 ] && [ "$EX_LEN" -ge 50 ]; then exit 0; else exit 1; fi
EOF
chmod +x ~/soc-ai-lab/scripts/tests/e2e_run_scenario.sh