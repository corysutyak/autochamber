#!/usr/bin/env bash
set -euo pipefail

echo "== Installing Docker =="

if command -v docker >/dev/null 2>&1; then
  echo "Docker already installed"
  exit 0
fi

sudo apt remove -y docker docker.io containerd runc 2>/dev/null || true

sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release

sudo install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" \
| sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

sudo systemctl enable docker
sudo systemctl start docker

CURRENT_USER="${SUDO_USER:-$USER}"
sudo usermod -aG docker "$CURRENT_USER" || true

# Mark that we added the user to the docker group (for uninstall awareness)
sudo mkdir -p /var/lib/autochamber
sudo touch /var/lib/autochamber/docker-group-added

echo "Docker installed"
echo ""
echo "NOTE: Docker group membership requires re-login. Run 'newgrp docker' or re-login."