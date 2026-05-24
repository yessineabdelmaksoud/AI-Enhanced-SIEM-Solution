#!/bin/bash
set -euo pipefail

MODEL="${MODEL:-qwen3:14b}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"

echo "=========================================="
echo " SOC-AI Pull and Test Ollama Model"
echo "=========================================="
echo "Model: $MODEL"
echo "Ollama URL: $OLLAMA_URL"
echo

echo "[1/5] Checking Ollama API..."
if ! curl -s "$OLLAMA_URL/api/tags" >/dev/null; then
  echo "ERROR: Ollama API is not reachable at $OLLAMA_URL"
  echo "Check: systemctl status ollama OR docker ps"
  exit 1
fi

echo "[2/5] Pulling model..."
ollama pull "$MODEL"

echo "[3/5] Listing installed models..."
ollama list

echo "[4/5] Keeping model loaded..."
curl -s "$OLLAMA_URL/api/generate" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$MODEL\",
    \"prompt\": \"Return only JSON: {\\\"status\\\":\\\"ok\\\"}\",
    \"stream\": false,
    \"think\": false,
    \"keep_alive\": \"1h\",
    \"options\": {
      \"temperature\": 0.1,
      \"num_predict\": 100
    }
  }" | jq

echo "[5/5] Simple JSON test..."
RESPONSE=$(curl -s "$OLLAMA_URL/api/generate" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$MODEL\",
    \"prompt\": \"Return ONLY valid JSON with this exact structure: {\\\"status\\\":\\\"ok\\\",\\\"model\\\":\\\"$MODEL\\\"}\",
    \"stream\": false,
    \"format\": \"json\",
    \"think\": false,
    \"options\": {
      \"temperature\": 0.1,
      \"num_predict\": 200
    }
  }")

echo "$RESPONSE" | jq

if echo "$RESPONSE" | jq -e '.response | fromjson | .status == "ok"' >/dev/null 2>&1; then
  echo "JSON test: OK"
else
  echo "WARNING: Model responded, but JSON parsing failed."
  echo "This can happen with Qwen3 thinking mode or too small num_predict."
fi

echo "=========================================="
echo " Model pull/test finished"
echo "=========================================="