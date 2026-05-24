#!/bin/bash

set -e

echo "======================================"
echo " OLLAMA VM SETUP - CPU/GPU AUTO MODE"
echo "======================================"

echo ""
echo "[1/9] System information"
lsb_release -a || true
uname -m

ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" && "$ARCH" != "amd64" ]]; then
  echo "ERROR: This script expects amd64/x86_64 architecture."
  exit 1
fi

echo ""
echo "[2/9] Updating system"
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release software-properties-common

echo ""
echo "[3/9] Installing Docker official repository"

sudo install -m 0755 -d /etc/apt/keyrings

if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
fi

sudo chmod a+r /etc/apt/keyrings/docker.asc

UBUNTU_CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")

sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update

echo ""
echo "[4/9] Installing Docker Engine"
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo ""
echo "[5/9] Starting Docker"
sudo systemctl enable docker
sudo systemctl start docker

echo ""
echo "[6/9] Adding current user to docker group"
sudo usermod -aG docker "$USER" || true

echo ""
echo "[7/9] Checking GPU availability"

GPU_AVAILABLE=false

if command -v nvidia-smi >/dev/null 2>&1; then
  if nvidia-smi >/dev/null 2>&1; then
    GPU_AVAILABLE=true
  fi
fi

if [ "$GPU_AVAILABLE" = true ]; then
  echo "NVIDIA GPU detected."

  echo ""
  echo "[7.1/9] Installing NVIDIA Container Toolkit"

  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null

  sudo apt update
  sudo apt install -y nvidia-container-toolkit

  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker

  echo ""
  echo "[7.2/9] Testing GPU inside Docker"
  sudo docker run --rm --gpus all nvidia/cuda:12.3.2-base-ubuntu22.04 nvidia-smi

else
  echo "No NVIDIA GPU detected or nvidia-smi not working."
  echo "Ollama will run in CPU-only mode."
fi

echo ""
echo "[8/9] Installing Ollama Docker container"

sudo docker pull ollama/ollama

if sudo docker ps -a --format '{{.Names}}' | grep -q '^ollama$'; then
  echo "Existing Ollama container found. Removing it..."
  sudo docker stop ollama || true
  sudo docker rm ollama || true
fi

if [ "$GPU_AVAILABLE" = true ]; then
  echo "Starting Ollama with GPU support..."
  sudo docker run -d \
    --name ollama \
    --restart unless-stopped \
    --gpus all \
    -v ollama:/root/.ollama \
    -p 11434:11434 \
    ollama/ollama
else
  echo "Starting Ollama in CPU-only mode..."
  sudo docker run -d \
    --name ollama \
    --restart unless-stopped \
    -v ollama:/root/.ollama \
    -p 11434:11434 \
    ollama/ollama
fi

echo ""
echo "[9/9] Verification"

sleep 5

echo ""
echo "Docker containers:"
sudo docker ps

echo ""
echo "Ollama version:"
sudo docker exec ollama ollama --version || true

echo ""
echo "Ollama API test:"
curl -s http://localhost:11434/api/tags || true

echo ""
echo "======================================"
echo " SETUP FINISHED"
echo "======================================"

echo ""
echo "Important:"
echo "If you want to use docker without sudo, logout/login or run:"
echo "newgrp docker"

echo ""
echo "Recommended first model test for CPU VM:"
echo "sudo docker exec -it ollama ollama run llama3.1:8b"

echo ""
echo "For Qwen 14B Q4_K_M, use only if RAM is enough."
echo "With 32 GB RAM, it should run, but CPU-only will be slow."

echo ""
echo "Check running models with:"
echo "sudo docker exec -it ollama ollama ps"

echo ""
echo "Check logs with:"
echo "sudo docker logs ollama --tail 100"