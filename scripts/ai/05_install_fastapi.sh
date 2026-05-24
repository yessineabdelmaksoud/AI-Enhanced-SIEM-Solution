#!/bin/bash
set -euo pipefail

# Install FastAPI venv + systemd service for SOC AI Enrichment API
PROJECT_ROOT="${PROJECT_ROOT:-/home/vm-ai/soc-ai-lab}"
VENV_DIR="$PROJECT_ROOT/app/fastapi/.venv"
APP_DIR="$PROJECT_ROOT/app/fastapi"
SERVICE_FILE="/etc/systemd/system/soc-ai-fastapi.service"

echo "=========================================="
echo " SOC-AI FastAPI installation"
echo "=========================================="

# 1. Prerequisites
[ -f "$PROJECT_ROOT/config/.env" ] || { echo "ERROR: config/.env missing"; exit 1; }
[ -f "$APP_DIR/requirements.txt" ] || { echo "ERROR: requirements.txt missing"; exit 1; }
[ -f "$PROJECT_ROOT/systemd/soc-ai-fastapi.service" ] || { echo "ERROR: systemd unit missing"; exit 1; }

# 2. Create venv
echo "[1/4] Creating Python venv at $VENV_DIR"
if [ ! -d "$VENV_DIR" ]; then
  python3.11 -m venv "$VENV_DIR"
fi

# 3. Install dependencies
echo "[2/4] Installing requirements"
"$VENV_DIR/bin/pip" install --upgrade pip --quiet
"$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"

# 4. Install systemd service
echo "[3/4] Installing systemd service"
sudo cp "$PROJECT_ROOT/systemd/soc-ai-fastapi.service" "$SERVICE_FILE"
sudo systemctl daemon-reload

# 5. Enable + restart
echo "[4/4] Enabling and starting service"
sudo systemctl enable soc-ai-fastapi
sudo systemctl restart soc-ai-fastapi

sleep 3
sudo systemctl status soc-ai-fastapi --no-pager || true

echo ""
echo "=========================================="
echo " Installation finished"
echo "=========================================="
echo "Test: curl http://localhost:8000/health"
echo "Logs: sudo journalctl -u soc-ai-fastapi -f"
