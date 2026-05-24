#!/bin/bash
set -euo pipefail

# ============================================================
# Benchmark Qwen3 14B latency on realistic SOC prompt
# 1 warmup excluded + 5 measured runs
# Metrics: total time, generation time, tokens/s, JSON validity
# Verdict:
#   OK      : P95 approximation <= 90s
#   WARNING : P95 approximation <= 150s
#   FAIL    : P95 approximation > 150s
# ============================================================

PROMPT_FILE="${PROMPT_FILE:-$HOME/soc-ai-lab/data/samples/benchmark_prompt.txt}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
MODEL="${MODEL:-qwen3:14b}"
LOG_DIR="${LOG_DIR:-$HOME/soc-ai-lab/logs}"
RUNS="${RUNS:-5}"
NUM_PREDICT="${NUM_PREDICT:-600}"
NUM_CTX="${NUM_CTX:-4096}"
LOG_FILE="$LOG_DIR/benchmark_$(date +%Y%m%d_%H%M%S).txt"

mkdir -p "$LOG_DIR"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required. Install it with: sudo apt install -y jq"
  exit 1
fi

if ! command -v bc >/dev/null 2>&1; then
  echo "ERROR: bc is required. Install it with: sudo apt install -y bc"
  exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: prompt file not found at $PROMPT_FILE"
  exit 1
fi

if ! curl -s "$OLLAMA_URL/api/tags" >/dev/null; then
  echo "ERROR: Ollama API is not reachable at $OLLAMA_URL"
  exit 1
fi

PROMPT=$(cat "$PROMPT_FILE")

run_inference() {
  local payload
  payload=$(jq -n \
    --arg model "$MODEL" \
    --arg prompt "$PROMPT" \
    --argjson num_predict "$NUM_PREDICT" \
    --argjson num_ctx "$NUM_CTX" \
    '{
      model: $model,
      prompt: $prompt,
      stream: false,
      format: "json",
      think: false,
      keep_alive: "1h",
      options: {
        temperature: 0.2,
        top_p: 0.9,
        num_predict: $num_predict,
        num_ctx: $num_ctx
      }
    }')

  curl -s -X POST "$OLLAMA_URL/api/generate" \
       -H "Content-Type: application/json" \
       -d "$payload"
}

extract_metrics() {
  local response="$1"
  echo "$response" | jq -r '
    [
      ((.total_duration // 0) / 1000000000),
      ((.prompt_eval_duration // 0) / 1000000000),
      ((.eval_duration // 0) / 1000000000),
      (.prompt_eval_count // 0),
      (.eval_count // 0),
      (
        if ((.eval_duration // 0) > 0) then
          ((.eval_count // 0) / ((.eval_duration // 0) / 1000000000))
        else
          0
        end
      ),
      (.done_reason // "unknown")
    ] | @tsv'
}

validate_json() {
  local response="$1"
  echo "$response" | jq -e '.response | fromjson | .summary' >/dev/null 2>&1
}

stats() {
  printf '%s\n' "$@" | sort -n | awk '
    { a[NR]=$1; sum+=$1 }
    END {
      n=NR
      if (n == 0) exit 1
      median = (n%2==1) ? a[(n+1)/2] : (a[n/2]+a[n/2+1])/2
      printf "  min=%.2f  p50=%.2f  max_p95_approx=%.2f  mean=%.2f\n", a[1], median, a[n], sum/n
    }'
}

echo "=========================================="
echo " Benchmark SOC-AI LLM"
echo " Date       : $(date)"
echo " Prompt     : $PROMPT_FILE"
echo " Model      : $MODEL"
echo " Ollama URL : $OLLAMA_URL"
echo " Runs       : $RUNS"
echo " num_predict: $NUM_PREDICT"
echo " num_ctx    : $NUM_CTX"
echo "=========================================="
echo

echo ">>> Warmup excluded from metrics..."
run_inference >/dev/null
echo "Warmup finished."
echo

declare -a TOTAL_TIMES
declare -a GEN_TIMES
declare -a TPS_VALUES
VALID_COUNT=0

{
  echo "date,run,total_s,prompt_eval_s,generation_s,prompt_tokens,output_tokens,tokens_per_second,json_valid,done_reason"
} > "$LOG_FILE.csv"

for i in $(seq 1 "$RUNS"); do
  echo ">>> Run $i/$RUNS..."

  RESPONSE=$(run_inference)

  if validate_json "$RESPONSE"; then
    VALID_COUNT=$((VALID_COUNT + 1))
    JSON_OK="OK"
  else
    JSON_OK="INVALID"
  fi

  METRICS=$(extract_metrics "$RESPONSE")
  TOTAL=$(echo "$METRICS" | cut -f1)
  PEVAL=$(echo "$METRICS" | cut -f2)
  GEN=$(echo "$METRICS" | cut -f3)
  PCOUNT=$(echo "$METRICS" | cut -f4)
  ECOUNT=$(echo "$METRICS" | cut -f5)
  TPS=$(echo "$METRICS" | cut -f6)
  DONE_REASON=$(echo "$METRICS" | cut -f7)

  TOTAL_TIMES+=("$TOTAL")
  GEN_TIMES+=("$GEN")
  TPS_VALUES+=("$TPS")

  printf "  total=%.1fs  prompt_eval=%.1fs  generation=%.1fs  prompt_tok=%s  out_tok=%s  tps=%.2f  json=%s  done=%s\n" \
    "$TOTAL" "$PEVAL" "$GEN" "$PCOUNT" "$ECOUNT" "$TPS" "$JSON_OK" "$DONE_REASON"

  echo "$(date -Iseconds),$i,$TOTAL,$PEVAL,$GEN,$PCOUNT,$ECOUNT,$TPS,$JSON_OK,$DONE_REASON" >> "$LOG_FILE.csv"

  echo "$RESPONSE" > "$LOG_DIR/benchmark_run_${i}_$(date +%Y%m%d_%H%M%S).json"
done

echo
echo "=========================================="
echo " Statistics"
echo "=========================================="

echo "Total time (s):"
stats "${TOTAL_TIMES[@]}"

echo "Generation time (s):"
stats "${GEN_TIMES[@]}"

echo "Tokens/s:"
stats "${TPS_VALUES[@]}"

echo
echo "JSON valid: $VALID_COUNT/$RUNS"

MEDIAN_TOTAL=$(printf '%s\n' "${TOTAL_TIMES[@]}" | sort -n | awk -v n="$RUNS" '
  { a[NR]=$1 }
  END {
    if (n%2==1) print a[(n+1)/2];
    else print (a[n/2]+a[n/2+1])/2;
  }')

P95_APPROX=$(printf '%s\n' "${TOTAL_TIMES[@]}" | sort -n | tail -1)

echo
echo "=========================================="
echo " VERDICT"
echo "=========================================="

if (( $(echo "$P95_APPROX <= 90" | bc -l) )); then
  VERDICT="OK - Continue with Qwen3 14B"
elif (( $(echo "$P95_APPROX <= 150" | bc -l) )); then
  VERDICT="WARNING - Acceptable, set OLLAMA_TIMEOUT_S=180"
else
  VERDICT="FAIL - Use smaller model such as qwen3:8b or request GPU"
fi

echo " P50 total time        : ${MEDIAN_TOTAL}s"
echo " P95 approximation     : ${P95_APPROX}s"
echo " JSON valid            : $VALID_COUNT/$RUNS"
echo " Verdict               : $VERDICT"
echo "=========================================="

{
  echo "Date          : $(date)"
  echo "Model         : $MODEL"
  echo "Prompt        : $PROMPT_FILE"
  echo "Runs          : $RUNS"
  echo "num_predict   : $NUM_PREDICT"
  echo "num_ctx       : $NUM_CTX"
  echo "P50 total     : ${MEDIAN_TOTAL}s"
  echo "P95 approx    : ${P95_APPROX}s"
  echo "Valid JSON    : $VALID_COUNT/$RUNS"
  echo "Verdict       : $VERDICT"
  echo "CSV           : $LOG_FILE.csv"
} > "$LOG_FILE"

echo
echo "Log written:"
echo "$LOG_FILE"
echo "$LOG_FILE.csv"