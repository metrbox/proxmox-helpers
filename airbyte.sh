#!/usr/bin/env bash
# Proxmox LXC Helper: Airbyte OSS (abctl)
# Author: ChatGPT (for Tayo) | MIT
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="Airbyte"
var_tags="${var_tags:-etl;integration}"
var_cpu="${var_cpu:-6}"
var_ram="${var_ram:-16384}"
var_disk="${var_disk:-60}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

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
  apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release tar
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

  # Install abctl
  curl -LsfS https://get.airbyte.com | bash -
  install -D -m 0755 abctl/abctl /usr/local/bin/abctl

  # Install Airbyte locally. Insecure cookies so HTTP works behind LXC IP.
  abctl local install --insecure-cookies

  # Capture credentials
  install -d -m 0755 /opt/airbyte
  abctl local credentials | tee /opt/airbyte/credentials.txt

  IP=$(hostname -I | awk '{print $1}')
  cat >/opt/airbyte/connection-info <<EOF
AIRBYTE_URL=http://${IP}:8000
CREDENTIALS_HINT=Run: abctl local credentials
EOF
  echo "Airbyte UI: http://${IP}:8000"
}

msg_info "Setting up ${APP} with abctl inside the container"
container_inline inline
msg_ok "Completed Successfully!\n"
