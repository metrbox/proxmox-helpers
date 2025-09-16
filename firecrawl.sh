#!/usr/bin/env bash
# Proxmox LXC Helper: Firecrawl
# Author: ChatGPT (for Tayo) | MIT
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="Firecrawl"
var_tags="${var_tags:-ai;crawler}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-85}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

FC_PORT="${FC_PORT:-3002}"

header_info "$APP"
variables
color
catch_errors
start
build_container
description

inline() {
  set -e
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl gnupg git lsb-release
  install -d -m 0755 /etc/apt/keyrings

  # Docker + compose plugin
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
  fi

  # Layout
  install -d -m 0755 /opt/firecrawl
  cd /opt/firecrawl
  if [ ! -d repo ]; then
    git clone --depth=1 https://github.com/firecrawl/firecrawl.git repo
  fi
  cd repo

  # Minimal .env for self-hosting (Redis + Playwright service)
  cat > .env <<EOF
NUM_WORKERS_PER_QUEUE=8
PORT=${FC_PORT}
HOST=0.0.0.0
REDIS_URL=redis://redis:6379
REDIS_RATE_LIMIT_URL=redis://redis:6379
PLAYWRIGHT_MICROSERVICE_URL=http://playwright-service:3000/html
USE_DB_AUTHENTICATION=false
LOGGING_LEVEL=INFO
EOF

  # Bring up the stack
  docker compose build
  docker compose up -d

  IP=$(hostname -I | awk '{print $1}')
  cat >/opt/firecrawl/connection-info <<EOF
FIRECRAWL_API=http://${IP}:${FC_PORT}
ADMIN_QUEUES=http://${IP}:${FC_PORT}/admin/@/queues
EOF
  echo "Firecrawl API: http://${IP}:${FC_PORT}"
  echo "Queues UI:    http://${IP}:${FC_PORT}/admin/@/queues"
}

msg_info "Setting up ${APP} via Docker Compose inside the container"
container_inline inline
msg_ok "Completed Successfully!\n"
