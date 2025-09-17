#!/usr/bin/env bash
# Proxmox → LXC → Docker Compose → Airbyte OSS
# Works on Proxmox 7/8. Creates a Debian 12 LXC and installs Airbyte v0.60.0.
# No external "community-scripts" includes. Robust heredocs (no quote glitches).

set -Eeuo pipefail

# ---------------------------
# Tunables (override via env)
# ---------------------------
CTID="${CTID:-113}"                  # LXC ID to create
HN="${HN:-airbyte}"                  # Hostname for the LXC
TEMPLATE_STORE="${TEMPLATE_STORE:-local}"      # where cloud/template lives
ROOTFS_STORE="${ROOTFS_STORE:-local-lvm}"      # where container disk lives
DISK_GB="${DISK_GB:-60}"
CORES="${CORES:-6}"
MEM_MB="${MEM_MB:-16384}"

# Airbyte settings
AB_VER="${AB_VER:-0.60.0}"          # Airbyte version (Compose tag) - fallback to main if missing
AB_USER="${AB_USER:-airbyte}"
AB_PASS="${AB_PASS:-$(openssl rand -hex 12)}"  # override if you want a fixed password

# ---------------------------
# Helpers
# ---------------------------
die(){ echo "ERROR: $*" >&2; exit 1; }
exists_ct(){ pct status "$1" >/dev/null 2>&1; }

# ---------------------------
# Fetch Debian 12 template if missing
# ---------------------------
tmpl=$(pveam available | awk '/debian-12.*amd64.*standard/ {print $2}' | sort -V | tail -n1)
[ -n "$tmpl" ] || die "No Debian 12 standard template found in pveam available"
if ! pveam list "$TEMPLATE_STORE" | grep -q "$tmpl"; then
  echo "Downloading template $tmpl to $TEMPLATE_STORE …"
  pveam download "$TEMPLATE_STORE" "$tmpl"
fi

# ---------------------------
# Create LXC (unprivileged, Docker-friendly)
# ---------------------------
if exists_ct "$CTID"; then
  die "CT $CTID already exists. Set CTID to a free ID or remove the container first."
fi

pct create "$CTID" "${TEMPLATE_STORE}:vztmpl/${tmpl}" \
  -hostname "$HN" \
  -cores "$CORES" \
  -memory "$MEM_MB" \
  -swap 0 \
  -rootfs "${ROOTFS_STORE}:${DISK_GB}" \
  -net0 name=eth0,bridge=vmbr0,ip=dhcp \
  -unprivileged 1 \
  -features nesting=1,keyctl=1 || die "pct create failed"

# Relax LXC profile for Docker-in-LXC (common recipe)
CTCONF="/etc/pve/lxc/${CTID}.conf"
{
  echo "lxc.apparmor.profile: unconfined"
  echo "lxc.cgroup2.devices.allow: a"
  echo "lxc.cap.drop:"
} >> "$CTCONF"

pct start "$CTID" || die "pct start failed"

echo "Waiting for network in CT $CTID …"
for i in {1..30}; do
  pct exec "$CTID" -- bash -lc 'ping -c1 -W1 1.1.1.1 >/dev/null 2>&1' && break || sleep 2
  [ "$i" -eq 30 ] && die "Network did not come up in the container"
done

# ---------------------------
# Bootstrap inside the LXC
# ---------------------------
pct exec "$CTID" -- bash -lc "cat >/root/bootstrap-airbyte.sh <<'IN_CT'
#!/usr/bin/env bash
set -Eeuo pipefail

AB_VER='${AB_VER}'
AB_USER='${AB_USER}'
AB_PASS='${AB_PASS}'

echo '[1/5] Base packages …'
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release jq openssl

echo '[2/5] Docker CE + compose plugin …'
if ! command -v docker >/dev/null 2>&1; then
  install -d -m0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \\
\$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable\" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
fi

echo '[3/5] Airbyte files …'
install -d -m0755 /opt/airbyte
cd /opt/airbyte

# Try pinned compose first, then main
DL_OK=0
for URL in \
  \"https://raw.githubusercontent.com/airbytehq/airbyte-platform/v\${AB_VER}/airbyte-compute/src/main/docker/docker-compose.yaml\" \
  \"https://raw.githubusercontent.com/airbytehq/airbyte-platform/refs/heads/main/airbyte-compute/src/main/docker/docker-compose.yaml\" \
; do
  if curl -fsSLo airbyte.yaml \"\$URL\"; then
    DL_OK=1
    break
  fi
done
[ \"\$DL_OK\" = 1 ] || { echo \"Failed to download Airbyte docker-compose.yaml\" >&2; exit 1; }

# Patch variable-based volume targets to fixed paths (prevents 'invalid spec: …::')
sed -Ei \
  -e 's#workspace:\\$\\{WORKSPACE_ROOT\\}#workspace:/workspace#g' \
  -e 's#workspace:\\$\\{WORKSPACE_DOCKER_MOUNT\\}#workspace:/workspace#g' \
  -e 's#data:\\$\\{CONFIG_ROOT\\}#data:/data#g' \
  -e 's#data:\\$\\{DATA_DOCKER_MOUNT\\}#data:/data#g' \
  -e 's#local:\\$\\{LOCAL_ROOT\\}#local:/local#g' \
  -e 's#local:\\$\\{LOCAL_DOCKER_MOUNT\\}#local:/local#g' \
  -e 's#db:\\$\\{DB_DOCKER_MOUNT\\}#db:/db#g' \
  airbyte.yaml

# Minimal .env – only what the compose genuinely needs here
cat > .env <<EOF
VERSION=\${AB_VER}
BASIC_AUTH_USERNAME=\${AB_USER}
BASIC_AUTH_PASSWORD=\${AB_PASS}
EOF

echo '[4/5] Compose bring-up …'
# Validate expansion (should be quiet)
docker compose -f airbyte.yaml --env-file .env config >/dev/null

docker compose -f airbyte.yaml --env-file .env pull
docker compose -f airbyte.yaml --env-file .env up -d

# Wait for the UI to bind
for i in \$(seq 1 120); do
  curl -fsS 127.0.0.1:8000 >/dev/null 2>&1 && break || sleep 1
done

# Best-effort: ensure Temporal default namespace exists if service is present
if docker ps --format '{{.Names}}' | grep -q '^airbyte-temporal$'; then
  docker exec airbyte-temporal tctl --ns default namespace describe >/dev/null 2>&1 || \
  docker exec airbyte-temporal tctl --ns default namespace register --rd 3 || true
fi

IP=\$(hostname -I | awk '{print \$1}')
echo \"Airbyte UI:  http://\${IP}:8000\"
echo \"Credentials: \${AB_USER} / \${AB_PASS}\" | tee /opt/airbyte/credentials.txt

echo '[5/5] Running containers:'
docker compose -f airbyte.yaml --env-file .env ps
IN_CT
chmod +x /root/bootstrap-airbyte.sh
bash /root/bootstrap-airbyte.sh
"

echo
echo "==================== DONE ===================="
IP=$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" | tr -d '\r')
echo "Airbyte UI:  http://$IP:8000"
echo "User / Pass: ${AB_USER} / ${AB_PASS}"
echo "To view logs: pct exec $CTID -- bash -lc 'cd /opt/airbyte && docker compose -f airbyte.yaml --env-file .env logs --tail=200'"
