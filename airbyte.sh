#!/usr/bin/env bash
# Proxmox LXC Helper: Airbyte OSS (docker-compose)
# Author: Tayo | MIT
set -Eeuo pipefail

# ---- Proxmox LXC bootstrap helpers ----
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
APP="Airbyte"
var_tags="${var_tags:-etl;integration}"
var_cpu="${var_cpu:-6}"
var_ram="${var_ram:-16384}"
var_disk="${var_disk:-60}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"
var_ab_password="${var_ab_password:-$(openssl rand -hex 8)}" # Allow user-defined password, generate if empty

header_info "$APP"
variables
color
catch_errors

# --- Main installation logic to be run inside the container ---
inline_script() {
  set -Eeuo pipefail
  local AIRBYTE_VERSION="0.60.0" # Centralized version number for easy updates

  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release jq
  install -d -m 0755 /etc/apt/keyrings

  # Docker CE + compose plugin
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
  fi

  install -d -m 0755 /opt/airbyte
  cd /opt/airbyte

  # Fetch Airbyte docker-compose (two fallbacks)
  URLS=(
    "https://raw.githubusercontent.com/airbytehq/airbyte-platform/v${AIRBYTE_VERSION}/airbyte-compute/src/main/docker/docker-compose.yaml"
    "https://raw.githubusercontent.com/airbytehq/airbyte-platform/main/airbyte-compute/src/main/docker/docker-compose.yaml"
  )
  for u in "${URLS[@]}"; do
    if curl -fsSLo airbyte.yaml "$u"; then
      break
    fi
  done
  if ! [ -s airbyte.yaml ]; then
    echo "Failed to download Airbyte docker-compose.yaml" >&2
    exit 1
  fi

  # Ensure directories (named volumes will be used; these are just for optional bind needs)
  mkdir -p /opt/airbyte/{workspace,local,db}

  # Patch volume targets to fixed container paths to avoid empty-var errors
  sed -Ei \
    -e 's#workspace:\$\{WORKSPACE_ROOT\}#workspace:/workspace#g' \
    -e 's#workspace:\$\{WORKSPACE_DOCKER_MOUNT\}#workspace:/workspace#g' \
    -e 's#data:\$\{CONFIG_ROOT\}#data:/data#g' \
    -e 's#data:\$\{DATA_DOCKER_MOUNT\}#data:/data#g' \
    -e 's#local:\$\{LOCAL_ROOT\}#local:/local#g' \
    -e 's#local:\$\{LOCAL_DOCKER_MOUNT\}#local:/local#g' \
    -e 's#db:\$\{DB_DOCKER_MOUNT\}#db:/db#g' \
    airbyte.yaml

  # Minimal .env (version + basic auth)
  cat > .env <<EOF
VERSION=${AIRBYTE_VERSION}
BASIC_AUTH_USERNAME=airbyte
BASIC_AUTH_PASSWORD=${var_ab_password}
EOF

  # Validate interpolation
  docker compose -f airbyte.yaml --env-file .env config >/dev/null

  # Pull & start
  docker compose -f airbyte.yaml --env-file .env pull
  docker compose -f airbyte.yaml --env-file .env up -d

  # Wait for UI
  echo "Waiting for Airbyte UI to become available... (This may take a few minutes)"
  for i in {1..90}; do
    if curl -fsS 127.0.0.1:8000 >/dev/null 2>&1; then 
      echo "Airbyte UI is up!"
      break
    fi
    echo -n "."
    sleep 2
  done

  # (best-effort) ensure Temporal default namespace exists
  if docker ps --format '{{.Names}}' | grep -q '^airbyte-temporal$'; then
    docker exec airbyte-temporal tctl --ns default namespace describe >/dev/null 2>&1 || \
    docker exec airbyte-temporal tctl --ns default namespace register --rd 3 || true
  fi
}

# --- Script execution ---
start
msg_info "Setting up Container OS"
build_lxc
msg_info "Setting up ${APP} via Docker Compose (LXC-friendly)"
# Execute the inline_script function within the container
lxc-attach -n "$CTID" -- bash -c "$(declare -f inline_script); inline_script"
IP=$(lxc-info -n "$CTID" -iH | awk '{print $1}')

# Pass password to script finish
cat <<EOF > /etc/motd.d/99-${APP}
--------------------------------------------------------------
 Application: ${APP}
 UI URL: http://${IP}:8000
 UI Login: airbyte / ${var_ab_password}
 --------------------------------------------------------------
EOF
motd_ssh

# Cleanup
rm -f /etc/motd.d/99-${APP}
msg_ok "Completed Successfully!"
