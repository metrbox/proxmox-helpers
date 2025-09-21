#!/usr/bin/env bash
# Proxmox LXC Helper: Sim Studio AI
# Author: Gemini
set -Eeuo pipefail

# ---- Proxmox LXC bootstrap helpers ----
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
APP="Sim Studio AI"
var_tags="${var_tags:-ai;simulation}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-32}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"
var_openai_api_key="" # User must provide this during setup

header_info "$APP"
variables
color
catch_errors
start

# --- Main installation logic to be run inside the container ---
inline_script() {
  set -Eeuo pipefail

  # --- Install Dependencies (Git, Docker) ---
  apt-get update
  apt-get install -y --no-install-recommends git ca-certificates curl gnupg
  install -d -m 0755 /etc/apt/keyrings

  if ! command -v docker &>/dev/null; then
    msg_info "Installing Docker..."
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
  fi

  # --- Clone Sim Studio AI Repository ---
  msg_info "Cloning Sim Studio AI repository..."
  git clone https://github.com/simstudioai/sim.git /opt/sim
  cd /opt/sim

  # --- Configure Environment File (.env) ---
  msg_info "Configuring environment..."
  cp .env.example .env

  # Get the container's IP address
  IP=$(hostname -I | awk '{print $1}')

  # Set the required variables in the .env file
  sed -i "s/^OPENAI_API_KEY=.*$/OPENAI_API_KEY=${var_openai_api_key}/" .env
  sed -i "s|^SIM_STUDIO_HOST_URL=.*$|SIM_STUDIO_HOST_URL=http://${IP}:8000|" .env
  
  # --- Pull and Start Application ---
  msg_info "Pulling Docker images (this may take a while)..."
  docker compose -f docker-compose.prod.yaml pull
  msg_info "Starting Sim Studio AI..."
  docker compose -f docker-compose.prod.yaml up -d

  # --- Wait for UI to be ready ---
  msg_info "Waiting for Sim Studio AI to become available..."
  for i in {1..60}; do
    if curl -fsS http://127.0.0.1:8000 >/dev/null 2>&1; then
      echo "Sim Studio AI is up!"
      break
    fi
    echo -n "."
    sleep 2
  done
}

# --- Script Execution ---
description # Set the container's description in the Proxmox GUI.
msg_info "Setting up ${APP}..."
container_inline inline_script # Create the container and run our custom installation function inside it.
motd_ssh # Create the Message of the Day file that displays info upon SSH login.
msg_ok "Completed Successfully!"

# Print the final URL and login details directly to the console for immediate use.
echo -e "${APP} UI is available at: \e[1;32mhttp://${IP}:8000\e[0m"
echo -e "The OpenAI API Key you provided has been configured."
