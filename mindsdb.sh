#!/usr/bin/env bash
# Proxmox LXC Helper to install MindsDB in a Debian 12 container
# Inspired by community-scripts/ProxmoxVE format (MIT)
# Author: ChatGPT (for Tayo)
# License: MIT

# Load common helpers (UI, LXC creation, checks)
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="MindsDB"
var_tags="${var_tags:-ai;database;automation}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-25}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

# --- Force INLINE-ONLY path (avoid any remote installer calls) ---
var_install=""   # <- ensures build.func won't try to fetch install/${var_install}.sh

# Optional: override MindsDB image tag (defaults to latest)
MDB_IMAGE="${MDB_IMAGE:-mindsdb/mindsdb:latest}"

# Which APIs to enable (http=47334, mysql=47335; add mongodb if you need it)
MDB_APIS="${MDB_APIS:-http,mysql}"

# Data dir inside the container image (mounted to host path for persistence)
# According to MindsDB docs, you can control storage via MINDSDB_STORAGE_DIR.
MDB_STORAGE_DIR="${MDB_STORAGE_DIR:-/root/mdb_storage}"

header_info "$APP"
variables
color
catch_errors

# -------- Update path (run this script with "update" inside the container) -------
function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if ! command -v docker &>/dev/null; then
    msg_error "Docker not found. Is this the ${APP} container?"
    exit 1
  fi
  msg_info "Pulling latest ${APP} image (${MDB_IMAGE})"
  $STD docker pull "${MDB_IMAGE}"
  msg_ok "Image pulled"

  msg_info "Restarting ${APP} container"
  if docker ps -a --format '{{.Names}}' | grep -q '^mindsdb$'; then
    $STD docker rm -f mindsdb
  fi

  # Recreate from stored env and volumes
  MDB_ENV_FILE="/opt/mindsdb/.env"
  if [[ -f "${MDB_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${MDB_ENV_FILE}"
  fi

  $STD docker run -d \
    --name mindsdb \
    --restart unless-stopped \
    -p 47334:47334 \
    -p 47335:47335 \
    -e MINDSDB_APIS="${MINDSDB_APIS:-$MDB_APIS}" \
    -e MINDSDB_STORAGE_DIR="${MINDSDB_STORAGE_DIR:-$MDB_STORAGE_DIR}" \
    -e MINDSDB_USERNAME="${MINDSDB_USERNAME:-admin}" \
    -e MINDSDB_PASSWORD="${MINDSDB_PASSWORD:-$MDB_PASSWORD}" \
    -v /opt/mindsdb/storage:"${MINDSDB_STORAGE_DIR:-$MDB_STORAGE_DIR}" \
    "${MDB_IMAGE}"

  msg_ok "Updated and restarted"

  IP=$(hostname -I | awk '{print $1}')
  echo -e "${INFO}${YW} Access UI: http://${IP}:47334${CL}"
  echo -e "${INFO}${YW} MySQL API: ${IP}:47335${CL}"
  exit 0
}

# -------------------------- LXC build + install path ----------------------------
start
build_container
# description            # REMOVED to avoid remote installer path

# Everything below runs inside the newly created container
inline() {
  set -e

  # Basic deps
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release pwgen
  install -d -m 0755 /etc/apt/keyrings

  # Docker CE
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io
    systemctl enable --now docker
  fi

  # MindsDB directory layout
  install -d -m 0755 /opt/mindsdb
  install -d -m 0755 /opt/mindsdb/storage

  # Generate credentials once
  if [[ ! -f /opt/mindsdb/.env ]]; then
    MDB_USER="admin"
    MDB_PASS="$(pwgen -s 16 1)"
    cat >/opt/mindsdb/.env <<EOF
MINDSDB_USERNAME=${MDB_USER}
MINDSDB_PASSWORD=${MDB_PASS}
MINDSDB_APIS=${MDB_APIS}
MINDSDB_STORAGE_DIR=${MDB_STORAGE_DIR}
EOF
    chmod 600 /opt/mindsdb/.env
  fi

  # Load env
  # shellcheck disable=SC1091
  source /opt/mindsdb/.env

  # Pull and run MindsDB
  docker pull "${MDB_IMAGE}"
  # Clean up any prior container with same name
  if docker ps -a --format '{{.Names}}' | grep -q '^mindsdb$'; then
    docker rm -f mindsdb
  fi

  docker run -d \
    --name mindsdb \
    --restart unless-stopped \
    -p 47334:47334 \
    -p 47335:47335 \
    -e MINDSDB_APIS="${MINDSDB_APIS}" \
    -e MINDSDB_STORAGE_DIR="${MINDSDB_STORAGE_DIR}" \
    -e MINDSDB_USERNAME="${MINDSDB_USERNAME}" \
    -e MINDSDB_PASSWORD="${MINDSDB_PASSWORD}" \
    -v /opt/mindsdb/storage:"${MINDSDB_STORAGE_DIR}" \
    "${MDB_IMAGE}"

  # Small helper: update alias
  cat >/usr/local/bin/mindsdb-update <<'EOS'
#!/usr/bin/env bash
set -e
if ! command -v docker &>/dev/null; then
  echo "Docker not found"
  exit 1
fi
docker pull mindsdb/mindsdb:latest
docker rm -f mindsdb || true
# shellcheck disable=SC1091
source /opt/mindsdb/.env
docker run -d \
  --name mindsdb \
  --restart unless-stopped \
  -p 47334:47334 \
  -p 47335:47335 \
  -e MINDSDB_APIS="${MINDSDB_APIS}" \
  -e MINDSDB_STORAGE_DIR="${MINDSDB_STORAGE_DIR}" \
  -e MINDSDB_USERNAME="${MINDSDB_USERNAME}" \
  -e MINDSDB_PASSWORD="${MINDSDB_PASSWORD}" \
  -v /opt/mindsdb/storage:"${MINDSDB_STORAGE_DIR}" \
  mindsdb/mindsdb:latest
EOS
  chmod +x /usr/local/bin/mindsdb-update

  # Print connection details
  IP=$(hostname -I | awk '{print $1}')
  echo "MINDSDB_URL=http://${IP}:47334" >/opt/mindsdb/connection-info
  echo "MYSQL_API=${IP}:47335" >>/opt/mindsdb/connection-info
  echo "USERNAME=${MINDSDB_USERNAME}" >>/opt/mindsdb/connection-info
  echo "PASSWORD=${MINDSDB_PASSWORD}" >>/opt/mindsdb/connection-info
}

msg_info "Setting up ${APP} (Docker-based) inside the container"
container_inline inline
msg_ok "Completed Successfully!\n"

# Final hints printed from Proxmox host with container IP
# If IP from helpers is empty, compute it from CT
if [[ -z "${IP:-}" && -n "${CTID:-}" ]]; then
  IP=$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null)
fi

echo -e "${CREATING}${GN}${APP} is up!${CL}"
echo -e "${INFO}${YW} Access via:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:47334${CL}"
echo -e "${INFO}${YW} MySQL API:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}${IP}:47335${CL}"
echo -e "${INFO}${YW} To retrieve credentials from inside the container:${CL}"
echo -e "${TAB}${BGN}cat /opt/mindsdb/connection-info${CL}"
