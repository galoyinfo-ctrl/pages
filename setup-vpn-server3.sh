#!/usr/bin/env bash
#
# setup-vpn-server.sh
# Bootstrap a low-resource Ubuntu 24.04 VPS as a 3x-ui (Xray) VPN box:
#   - swap file (helps on 1GB RAM)
#   - hardened SSH (new port, no root login, fail2ban)
#   - UFW firewall (default-deny, minimal open ports)
#   - unattended security upgrades
#   - optional BBR congestion control (better throughput on a single core)
#   - 3x-ui panel install with random credentials
#
# Run as root on a FRESH Ubuntu 24.04 VPS:
#   sudo bash setup-vpn-server.sh
#
# IMPORTANT: keep your CURRENT ssh session open until you've verified you
# can log in on the NEW port with the NEW user in a SEPARATE terminal.
set -euo pipefail

######################## CONFIG - edit if you want #########################
NEW_SSH_PORT=2244            # move off default 22
NEW_USERNAME="admin"         # new sudo user (root SSH login will be disabled)
PANEL_PORT=2053              # 3x-ui web panel port
SWAP_SIZE_MB=1024            # swap file size in MB (RAM is only 1GB)
##############################################################################

if [[ $EUID -ne 0 ]]; then
  echo "Please run this script as root (sudo bash setup-vpn-server.sh)" >&2
  exit 1
fi

. /etc/os-release
if [[ "${VERSION_ID:-}" != "24.04" ]]; then
  echo "Warning: this script targets Ubuntu 24.04. Detected: ${PRETTY_NAME:-unknown}. Continuing anyway..." >&2
fi

log() { echo -e "\n\033[1;32m==>\033[0m $1"; }

# NOTE: /dev/urandom never hits EOF, so piping it straight into `tr | head -c N`
# makes `tr` die from SIGPIPE the instant `head` closes the pipe early - under
# `set -e -o pipefail` that aborts the whole script. Reading a bounded chunk
# with the first `head -c` avoids that: tr then gets a finite input and exits
# cleanly on real EOF.
RAND_PASS() { head -c 300 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20; }
RAND_PATH()  { head -c 300 /dev/urandom | tr -dc 'a-z0-9' | head -c 12; }
RAND_SUFFIX() { head -c 300 /dev/urandom | tr -dc 'a-z0-9' | head -c 6; }

USER_PASSWORD="$(RAND_PASS)"
PANEL_USERNAME="admin_$(RAND_SUFFIX)"
PANEL_PASSWORD="$(RAND_PASS)"
PANEL_WEBPATH="/$(RAND_PATH)/"

######################## 1. System update ###################################
log "Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

######################## 2. Swap (low RAM safety net) #######################
log "Configuring ${SWAP_SIZE_MB}MB swap file"
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l "${SWAP_SIZE_MB}M" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  # Low-RAM tuning: swap only when needed, favor keeping cache
  sysctl -w vm.swappiness=10
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
else
  echo "Swap already present, skipping."
fi

######################## 3. Base packages ####################################
log "Installing base packages (ufw, fail2ban, unattended-upgrades, etc.)"
apt-get install -y --no-install-recommends \
  ufw fail2ban unattended-upgrades curl wget socat unzip ca-certificates cron

######################## 4. New sudo user ####################################
log "Creating sudo user '${NEW_USERNAME}'"
if ! id -u "${NEW_USERNAME}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${NEW_USERNAME}"
  usermod -aG sudo "${NEW_USERNAME}"
  echo "${NEW_USERNAME}:${USER_PASSWORD}" | chpasswd
else
  echo "User already exists, leaving password untouched."
  USER_PASSWORD="(unchanged - user already existed)"
fi

# Carry over root's authorized_keys to the new user, if any exist
mkdir -p "/home/${NEW_USERNAME}/.ssh"
if [[ -f /root/.ssh/authorized_keys ]]; then
  cp /root/.ssh/authorized_keys "/home/${NEW_USERNAME}/.ssh/authorized_keys"
fi
chmod 700 "/home/${NEW_USERNAME}/.ssh"
chmod 600 "/home/${NEW_USERNAME}/.ssh/authorized_keys" 2>/dev/null || true
chown -R "${NEW_USERNAME}:${NEW_USERNAME}" "/home/${NEW_USERNAME}/.ssh"

KEY_BASED_AUTH="no"
if [[ -s "/home/${NEW_USERNAME}/.ssh/authorized_keys" ]]; then
  KEY_BASED_AUTH="yes"
fi

######################## 5. Harden SSH #######################################
log "Hardening SSH (port ${NEW_SSH_PORT}, no root login)"
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"

set_sshd_option() {
  local key="$1" val="$2"
  if grep -qE "^\s*#?\s*${key}\b" "$SSHD_CONFIG"; then
    sed -i -E "s|^\s*#?\s*${key}\b.*|${key} ${val}|" "$SSHD_CONFIG"
  else
    echo "${key} ${val}" >> "$SSHD_CONFIG"
  fi
}

set_sshd_option "Port" "${NEW_SSH_PORT}"
set_sshd_option "PermitRootLogin" "no"
set_sshd_option "MaxAuthTries" "3"
set_sshd_option "ClientAliveInterval" "300"
set_sshd_option "ClientAliveCountMax" "2"
set_sshd_option "X11Forwarding" "no"
set_sshd_option "AllowTcpForwarding" "yes"   # needed by some VPN/tunnel workflows; set to "no" if unused
set_sshd_option "PermitEmptyPasswords" "no"
set_sshd_option "LoginGraceTime" "20"

if [[ "$KEY_BASED_AUTH" == "yes" ]]; then
  set_sshd_option "PasswordAuthentication" "no"
  set_sshd_option "PubkeyAuthentication" "yes"
else
  # No SSH key was found for root, so we leave password auth ON
  # so you don't get locked out. Add an SSH key ASAP, then disable this.
  set_sshd_option "PasswordAuthentication" "yes"
fi

# Validate config before applying
sshd -t -f "$SSHD_CONFIG"

######################## 6. fail2ban for SSH ##################################
log "Configuring fail2ban for SSH"
cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ${NEW_SSH_PORT}
maxretry = 4
findtime = 10m
bantime = 1h
EOF
systemctl enable fail2ban
systemctl restart fail2ban

######################## 7. Firewall (UFW) ####################################
log "Configuring UFW firewall"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${NEW_SSH_PORT}/tcp" comment 'SSH'
ufw allow "${PANEL_PORT}/tcp" comment '3x-ui panel'
ufw --force enable

######################## 8. Unattended security upgrades ######################
log "Enabling unattended security upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

######################## 9. BBR congestion control (optional, cheap win) ######
log "Enabling TCP BBR (helps throughput on a single-core box)"
cat > /etc/sysctl.d/98-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null

######################## 10. Install 3x-ui ####################################
log "Installing 3x-ui panel"
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<< "" || true

# Apply non-interactive panel settings via the x-ui CLI
if command -v x-ui >/dev/null 2>&1; then
  x-ui setting -username "${PANEL_USERNAME}" -password "${PANEL_PASSWORD}" -port "${PANEL_PORT}" -webBasePath "${PANEL_WEBPATH}" >/dev/null 2>&1 || \
  x-ui setting -username "${PANEL_USERNAME}" -password "${PANEL_PASSWORD}" -port "${PANEL_PORT}" || true
  systemctl restart x-ui
fi

######################## 11. Apply SSH changes last ############################
log "Applying SSH config and restarting sshd"
systemctl restart ssh || systemctl restart sshd

######################## 12. Cleanup (storage is tight) #######################
log "Cleaning up apt cache to save disk space"
apt-get autoremove -y
apt-get clean

SERVER_IP="$(curl -s -4 ifconfig.me || hostname -I | awk '{print $1}')"

######################## Summary ###############################################
cat <<SUMMARY

================= SETUP COMPLETE =================

>>> KEEP THIS SESSION OPEN. Test the items below in a NEW terminal window
>>> before you disconnect, so you don't get locked out.

SSH ACCESS
  Host:      ${SERVER_IP}
  Port:      ${NEW_SSH_PORT}
  User:      ${NEW_USERNAME}
  Password:  ${USER_PASSWORD}
  Root login: disabled
  Password auth: ${KEY_BASED_AUTH/yes/disabled (key-only)}${KEY_BASED_AUTH/no/enabled - no SSH key was found, add one then disable this}

  Test with:
    ssh -p ${NEW_SSH_PORT} ${NEW_USERNAME}@${SERVER_IP}

3X-UI PANEL
  URL:       http://${SERVER_IP}:${PANEL_PORT}${PANEL_WEBPATH}
  Username:  ${PANEL_USERNAME}
  Password:  ${PANEL_PASSWORD}

  Once logged in, create an inbound (e.g. VLESS+Reality or Trojan) and
  note whatever port you assign it - you MUST open that port too:
    ufw allow <your-inbound-port>/tcp

FIREWALL (UFW) - default deny incoming, only these are open:
  - ${NEW_SSH_PORT}/tcp  (SSH)
  - ${PANEL_PORT}/tcp    (3x-ui panel)

OTHER
  - fail2ban is active on SSH (4 tries / 10 min -> 1h ban)
  - Unattended security upgrades enabled
  - ${SWAP_SIZE_MB}MB swap enabled (swappiness=10)
  - BBR congestion control enabled

>>> SAVE THIS OUTPUT NOW - passwords are not stored anywhere else. <<<
====================================================
SUMMARY
