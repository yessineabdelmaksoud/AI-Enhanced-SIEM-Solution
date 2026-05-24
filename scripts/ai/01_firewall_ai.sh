#!/bin/bash
set -euo pipefail

# UFW for vm-ai: allow 22 + 8000 from internal subnet
SUBNET="${SUBNET:-10.110.188.0/24}"

if ! command -v ufw >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y ufw
fi

sudo ufw default deny incoming
sudo ufw default allow outgoing

# SSH
sudo ufw allow from "$SUBNET" to any port 22 proto tcp comment 'ssh internal'

# FastAPI
sudo ufw allow from "$SUBNET" to any port 8000 proto tcp comment 'soc-ai api'

sudo ufw --force enable
sudo ufw status numbered
