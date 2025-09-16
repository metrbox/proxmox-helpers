#!/usr/bin/env bash
# Proxmox LXC Helper: Crawl4AI
# Author: ChatGPT (for Tayo) | MIT
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="Crawl4AI"
var_tags="${var_tags:-ai;crawler}"
var_cpu="${var_cpu:-8}"
var_ram="${var_ram:-21096}"
var_disk="${var_disk:-200}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

C4_IMAGE="${C4_IMAGE:-unclecode/crawl4ai:latest}"
C4_PORT="${C4_PORT:-11235}"

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

  # Docker CE
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io
    systemctl enable --now docker
  fi

  install -d -m 0755 /opt/crawl4ai
  docker rm -f crawl4ai 2>/dev/null || true
  docker pull "${C4_IMAGE}"

  # Run Crawl4AI server
  docker run -d \
    --name crawl4ai \
    --restart unless-stopped \
    --shm-size=1g \
    -p ${C4_PORT}:11235 \
    "${C4_IMAGE}"

  IP=$(hostname -I | awk '{print $1}')
  cat >/opt/crawl4ai/connection-info <<EOF
Crawl4AI_URL=http://${IP}:${C4_PORT}
EOF
  echo "Crawl4AI running at http://${IP}:${C4_PORT}"
}

msg_info "Setting up ${APP} (Docker-based) inside the container"
container_inline inline
msg_ok "Completed Successfully!\n"
echo -e "${INFO}${YW} Access:${CL} ${TAB}${BGN}http://${IP}:${C4_PORT}${CL}"
