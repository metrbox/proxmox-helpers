#!/usr/bin/env bash
# Proxmox LXC Helper: Sim Studio AI
# Author: Gemini (patched)
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

# ❗️Provide your OpenAI key here or via environment before running
var_openai_api_key="${var_openai_api_key:-}"

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
  apt-get install -y --no-install-recommends git ca-certificates curl gnupg lsb-release
  install -d -m 0755 /etc/apt/keyrings

  if ! command -v docker >/dev/null 2>&1; then
    msg_info "Installing Docker..."
    curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
  fi

  # Sanity: docker usable?
  if ! docker info >/dev/null 2>&1; then
    echo "Docker is installed but not usable in this LXC. Ensure nesting is enabled and the container is privileged, or add features: { nesting: 1 }." >&2
    exit 1
  fi

  # --- Clone Sim Studio AI Repository ---
  msg_info "Cloning Sim Studio AI repository..."
  install -d -m 0755 /opt
  if [ ! -d /opt/sim/.git ]; then
    git clone https://github.com/simstudioai/sim.git /opt/sim
  fi
  cd /opt/sim

  # --- Determine compose file ---
  COMPOSE_FILE=""
  for f in docker-compose.prod.yaml docker-compose.yml docker-compose.yaml; do
    if [ -f "$f" ]; then COMPOSE_FILE="$f"; break; fi
  done
  if [ -z "$COMPOSE_FILE" ]; then
    echo "No docker-compose file found in repo. Check repository structure." >&2
    exit 1
  fi
  msg_info "Using compose file: $COMPOSE_FILE"

  # --- Configure Environment File (.env) ---
  msg_info "Configuring environment..."
  # Create .env if missing (prefer example if present)
  if [ ! -f .env ]; then
    if [ -f .env.example ]; then
      cp .env.example .env
    else
      touch .env
    fi
  fi

  # Get the container's IP address
  IP="$(hostname -I | awk '{print $1}')"

  # Upsert helper: ensure KEY=VALUE present (replace if exists, else append)
  upsert_env() {
    local key="$1"
    local val="$2"
    if grep -qE "^${key}=" .env; then
      sed -i "s|^${key}=.*$|${key}=${val}|" .env
    else
      printf "%s=%s\n" "$key" "$val" >> .env
    fi
  }

  # 🔐 OpenAI key (fail fast if empty; comment next 3 lines to allow empty)
  if [ -z "${var_openai_api_key:-}" ]; then
    echo "OPENAI_API_KEY is not set. Set var_openai_api_key before running." >&2
    exit 1
  fi

  upsert_env "OPENAI_API_KEY" "${var_openai_api_key:-}"
  upsert_env "SIM_STUDIO_HOST_URL" "http://${IP}:8000"

  # --- Pull and Start Application ---
  msg_info "Pulling Docker images (this may take a while)..."
  docker compose -f "$COMPOSE_FILE" pull
  msg_info "Starting Sim Studio AI..."
  docker compose -f "$COMPOSE_FILE" up -d

  # --- Wait for UI to be ready ---
  msg_info "Waiting for Sim Studio AI to become available on :8000..."
  ATTEMPTS=120
  until curl -fsS "http://127.0.0.1:8000" >/dev/null 2>&1; do
    ATTEMPTS=$((ATTEMPTS-1))
    [ "$ATTEMPTS" -le 0 ] && break
    sleep 2
  done

  if curl -fsS "http://127.0.0.1:8000" >/dev/null 2>&1; then
    echo "Sim Studio AI is up."
  else
    echo "Sim Studio AI did not become ready in time. Check 'docker compose -f $COMPOSE_FILE logs -f'." >&2
  fi

  # Save IP for the host to read back (optional)
  echo "$IP" > /root/sim_ip.txt
}

# --- Script Execution ---
description
msg_info "Setting up ${APP}..."
container_inline inline_script
motd_ssh
msg_ok "Completed Successfully!"

# --- Post-provision: resolve CT IP on the host to avoid unbound vars ---
# The build.func helpers usually export CTID into the environment.
# If not available in your version, you may need to capture it from create step.
CTID="${CTID:-${CT_ID:-${var_ctid:-}}}"

if [ -n "${CTID:-}" ]; then
  # Try reading the IP file from the container first; fall back to hostname -I
  if pct exec "$CTID" -- test -f /root/sim_ip.txt; then
    CT_IP="$(pct exec "$CTID" -- cat /root/sim_ip.txt || true)"
  fi
  CT_IP="${CT_IP:-$(pct exec "$CTID" -- sh -lc "hostname -I | awk '{print \$1}'" || true)}"
fi

# Print the final URL and login details directly to the console for immediate use.
if [ -n "${CT_IP:-}" ]; then
  printf "%s UI is available at: \e[1;32mhttp://%s:8000\e[0m\n" "$APP" "$CT_IP"
else
  printf "%s deployed. Open the CT's IP on port 8000 (IP shown in Proxmox or 'pct exec <CTID> -- hostname -I').\n" "$APP"
fi
if [ -n "${var_openai_api_key:-}" ]; then
  echo "The OpenAI API Key you provided has been configured."
else
  echo "No OpenAI API Key configured. Update /opt/sim/.env inside the container."
fi
