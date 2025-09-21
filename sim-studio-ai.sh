#!/usr/bin/env bash
# Proxmox LXC Helper: Sim Studio AI
# Author: Gemini (fully patched, single-file version)
# Goal: Create a Debian 12 LXC on Proxmox, install Docker, deploy Sim Studio AI via docker compose.
# Safe with `set -u`: no unbound CTID/IP usage before it's available.

set -Eeuo pipefail

# ---- Proxmox LXC bootstrap helpers ----
# Uses community build helpers. Requires internet on the Proxmox host.
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# -----------------------------
#           SETTINGS
# -----------------------------
APP="Sim Studio AI"
# Container meta
var_tags="${var_tags:-ai;simulation}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-32}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
# Running Docker in LXC is smoother with nesting/keyctl enabled (still unprivileged by default)
var_unprivileged="${var_unprivileged:-1}"
var_features="${var_features:-nesting=1,keyctl=1}"

# OpenAI key:
# - You can export var_openai_api_key before running, or leave it empty and set inside the container later.
# - We DO NOT block the install if empty; the app may require it later.
var_openai_api_key="${var_openai_api_key:-}"

# -----------------------------
#       HELPER BANNERS
# -----------------------------
header_info "$APP"
variables
color
catch_errors
start

# -----------------------------
#           INLINE (CT)
# -----------------------------
inline_script() {
  set -Eeuo pipefail

  # --- Base deps ---
  apt-get update
  apt-get install -y --no-install-recommends git ca-certificates curl gnupg lsb-release
  install -d -m 0755 /etc/apt/keyrings

  # --- Docker (CE) + compose plugin ---
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

  # --- Sanity: Docker usable in this LXC? ---
  if ! docker info >/dev/null 2>&1; then
    echo "Docker installed but not usable in this LXC. Ensure features include 'nesting=1' (and often 'keyctl=1')." >&2
    exit 1
  fi

  # --- Fetch Sim Studio AI ---
  msg_info "Cloning Sim Studio AI repository..."
  install -d -m 0755 /opt
  if [ ! -d /opt/sim/.git ]; then
    git clone https://github.com/simstudioai/sim.git /opt/sim
  fi
  cd /opt/sim

  # --- Pick compose file automatically ---
  COMPOSE_FILE=""
  for f in docker-compose.prod.yaml docker-compose.yml docker-compose.yaml; do
    if [ -f "$f" ]; then COMPOSE_FILE="$f"; break; fi
  done
  if [ -z "$COMPOSE_FILE" ]; then
    echo "No docker-compose file found in /opt/sim." >&2
    exit 1
  fi
  msg_info "Using compose file: $COMPOSE_FILE"

  # --- .env configuration (idempotent) ---
  msg_info "Configuring environment..."
  if [ ! -f .env ]; then
    if [ -f .env.example ]; then
      cp .env.example .env
    else
      touch .env
    fi
  fi

  # Get CT IP for SIM_STUDIO_HOST_URL
  IP="$(hostname -I | awk '{print $1}')"

  # Upsert KEY=VALUE into .env (replace if exists, else append)
  upsert_env() {
    local key="$1" val="$2"
    if grep -qE "^${key}=" .env; then
      sed -i "s|^${key}=.*$|${key}=${val}|" .env
    else
      printf "%s=%s\n" "$key" "$val" >> .env
    fi
  }

  # Only set OPENAI_API_KEY if provided (don’t block install if empty)
  if [ -n "${var_openai_api_key:-}" ]; then
    upsert_env "OPENAI_API_KEY" "${var_openai_api_key}"
  else
    # Ensure key exists (possibly blank) so users can edit later
    if ! grep -qE "^OPENAI_API_KEY=" .env; then
      printf "OPENAI_API_KEY=\n" >> .env
    fi
  fi

  upsert_env "SIM_STUDIO_HOST_URL" "http://${IP}:8000"

  # --- Deploy ---
  msg_info "Pulling Docker images..."
  docker compose -f "$COMPOSE_FILE" pull

  msg_info "Starting Sim Studio AI..."
  docker compose -f "$COMPOSE_FILE" up -d

  # --- Readiness probe (up to ~4 minutes) ---
  msg_info "Waiting for Sim Studio AI on :8000..."
  ATTEMPTS=120
  until curl -fsS "http://127.0.0.1:8000" >/dev/null 2>&1; do
    ATTEMPTS=$((ATTEMPTS-1))
    [ "$ATTEMPTS" -le 0 ] && break
    sleep 2
  done

  if curl -fsS "http://127.0.0.1:8000" >/dev/null 2>&1; then
    echo "Sim Studio AI is up."
  else
    echo "Sim Studio AI did not become ready in time. Check: docker compose -f $COMPOSE_FILE logs -f" >&2
  fi

  # Make IP discoverable from the host post-provision
  echo "$IP" > /root/sim_ip.txt
}

# -----------------------------
#       CREATE & CONFIG
# -----------------------------
# NOTE: Some helper functions (like description/motd_ssh) require CTID to exist.
# We therefore ONLY call them *after* container_inline (which creates the CT).
msg_info "Creating and configuring ${APP} container..."
container_inline inline_script

# Try to set description and MOTD if CTID is available
if [ -n "${CTID:-}" ]; then
  description || true
  motd_ssh || true
fi

msg_ok "Completed Successfully!"

# -----------------------------
#     POST-PROVISION OUTPUT
# -----------------------------
# Everything below is guarded to avoid 'CTID: unbound variable' under set -u.

CT_IP=""

if [ -n "${CTID:-}" ]; then
  # Prefer the IP file created inside the CT; fall back to hostname -I
  if pct exec "$CTID" -- test -f /root/sim_ip.txt; then
    CT_IP="$(pct exec "$CTID" -- cat /root/sim_ip.txt || true)"
  fi
  if [ -z "$CT_IP" ]; then
    # Portable IP retrieval (no hard-coded interface names)
    CT_IP="$(pct exec "$CTID" -- sh -lc "hostname -I | awk '{print \$1}'" || true)"
  fi
fi

# Final messages (no unbound variables)
if [ -n "$CT_IP" ]; then
  printf "%s UI is available at: \e[1;32mhttp://%s:8000\e[0m\n" "$APP" "$CT_IP"
else
  echo "$APP deployed. Open the container's IP on port 8000."
  if [ -n "${CTID:-}" ]; then
    echo "Tip: In Proxmox UI > CT $CTID > Summary, copy the IP; or run: pct exec $CTID -- hostname -I"
  else
    echo "Note: CTID not exported by helper; if needed, find it with: pct list"
  fi
fi

if [ -n "${var_openai_api_key:-}" ]; then
  echo "OPENAI_API_KEY configured in /opt/sim/.env inside the container."
else
  echo "No OPENAI_API_KEY set. Edit /opt/sim/.env in the container, then: docker compose up -d"
fi
