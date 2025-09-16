#!/usr/bin/env bash
# Proxmox LXC Helper: Jitsu (joint image)
# Author: ChatGPT (for Tayo) | MIT
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="Jitsu"
var_tags="${var_tags:-analytics;ingestion}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-6144}"
var_disk="${var_disk:-25}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

JITSU_TAG="${JITSU_TAG:-latest}"
JITSU_PORT="${JITSU_PORT:-8000}"

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
  apt-get install -y --no-install-recommends ca-certificates curl gnupg pwgen lsb-release
  install -d -m 0755 /etc/apt/keyrings

  # Docker
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io
    systemctl enable --now docker
  fi

  install -d -m 0777 /opt/jitsu/logs_server
  install -d -m 0777 /opt/jitsu/logs_config

  # Redis
  docker rm -f jitsu-redis 2>/dev/null || true
  docker run -d --name jitsu-redis --restart unless-stopped -p 6379:6379 redis:7

  # Jitsu joint image (Configurator + Server on 8000)
  docker rm -f jitsu 2>/dev/null || true
  ADMIN_TOKEN="$(pwgen -s 24 1)"
  docker run -d \
    --name jitsu \
    --restart unless-stopped \
    -p ${JITSU_PORT}:8000 \
    -e REDIS_URL=redis://jitsu-redis:6379 \
    -e CLUSTER_ADMIN_TOKEN="${ADMIN_TOKEN}" \
    -v /opt/jitsu/logs_server:/home/eventnative/data/logs \
    -v /opt/jitsu/logs_config:/home/configurator/data/logs \
    --link jitsu-redis:redis \
    jitsucom/jitsu:${JITSU_TAG}

  IP=$(hostname -I | awk '{print $1}')
  cat >/opt/jitsu/connection-info <<EOF
JITSU_URL=http://${IP}:${JITSU_PORT}
ADMIN_TOKEN=${ADMIN_TOKEN}
REDIS=redis://${IP}:6379
EOF
  echo "Jitsu: http://${IP}:${JITSU_PORT}  (Admin token saved in /opt/jitsu/connection-info)"
}

msg_info "Setting up ${APP} inside the container"
container_inline inline
msg_ok "Completed Successfully!\n"
