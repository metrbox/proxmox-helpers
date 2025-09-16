#!/usr/bin/env bash
# Proxmox LXC Helper: Tracardi (Open Source)
# Author: ChatGPT (for Tayo) | MIT
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="Tracardi"
var_tags="${var_tags:-cdp;analytics}"
var_cpu="${var_cpu:-6}"
var_ram="${var_ram:-16384}"
var_disk="${var_disk:-80}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

TRACARDI_API_TAG="${TRACARDI_API_TAG:-1.1.1}"     # pin to a released tag
TRACARDI_GUI_TAG="${TRACARDI_GUI_TAG:-0.9.0.7}"   # keep API and GUI compatible
ES_TAG="${ES_TAG:-8.12.2}"

API_PORT="${API_PORT:-8686}"
GUI_PORT="${GUI_PORT:-8787}"

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
  apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release
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

  # Network
  docker network create tracardi_net 2>/dev/null || true

  # Elasticsearch single node (8.x needs discovery.type and memlock ulimits)
  docker rm -f es 2>/dev/null || true
  docker run -d --name es --restart unless-stopped --net tracardi_net \
    -p 9200:9200 \
    -e discovery.type=single-node \
    -e xpack.security.enabled=false \
    --ulimit memlock=-1:-1 \
    docker.elastic.co/elasticsearch/elasticsearch:${ES_TAG}

  # Redis
  docker rm -f redis 2>/dev/null || true
  docker run -d --name redis --restart unless-stopped --net tracardi_net -p 6379:6379 redis:7

  # Tracardi API (points to ES + Redis)
  docker rm -f tracardi-api 2>/dev/null || true
  docker run -d --name tracardi-api --restart unless-stopped --net tracardi_net \
    -p ${API_PORT}:80 \
    -e ELASTIC_HOST=http://es:9200 \
    -e REDIS_HOST=redis://redis:6379 \
    tracardi/tracardi-api:${TRACARDI_API_TAG}

  # Tracardi GUI on 8787, env points GUI to API
  docker rm -f tracardi-gui 2>/dev/null || true
  docker run -d --name tracardi-gui --restart unless-stopped --net tracardi_net \
    -p ${GUI_PORT}:80 \
    -e API_URL=//localhost:${API_PORT} \
    tracardi/tracardi-gui:${TRACARDI_GUI_TAG}

  IP=$(hostname -I | awk '{print $1}')
  install -d -m 0755 /opt/tracardi
  cat >/opt/tracardi/connection-info <<EOF
TRACARDI_API=http://${IP}:${API_PORT}
TRACARDI_GUI=http://${IP}:${GUI_PORT}
DEFAULT_LOGIN=admin / admin
ELASTIC=http://${IP}:9200
REDIS=redis://${IP}:6379
EOF
  echo "Tracardi GUI:  http://${IP}:${GUI_PORT}  (login admin/admin)"
  echo "Tracardi API:  http://${IP}:${API_PORT}  docs at /docs"
}

msg_info "Setting up ${APP} stack (ES + Redis + API + GUI)"
container_inline inline
msg_ok "Completed Successfully!\n"
