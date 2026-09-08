#!/usr/bin/env bash
#
# VPN Server Setup Script — Ubuntu 24.04
# Installs 3x-ui panel, hardens SSH, configures UFW firewall + fail2ban
#
# USAGE:
#   1. Edit the CONFIG section below before running.
#   2. Run as root: sudo bash setup-vpn-server.sh
#
set -euo pipefail

# ============================================================
# CONFIG — EDIT THESE BEFORE RUNNING
# ============================================================
NEW_SSH_PORT=2222              # change from default 22 (reduces bot scans)
PANEL_PORT=54321                # 3x-ui web panel port
SSH_PUBLIC_KEY=""               # paste your SSH public key here, e.g. "ssh-ed25519 AAAA... you@host"
                                 # if left empty, password auth stays ON (less secure, but safe)
ENABLE_AUTO_SECURITY_UPDATES=true
# ============================================================

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo bash $0)"
  exit 1
fi

echo "==> Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

echo "==> Installing base dependencies..."
apt-get install -y curl wget socat ufw fail2ban unattended-upgrades ca-certificates

# ------------------------------------------------------------
# SSH HARDENING
# ------------------------------------------------------------
echo "==> Hardening SSH configuration..."

SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"

# Add key if provided
KEY_INSTALLED=false
if [[ -n "$SSH_PUBLIC_KEY" ]]; then
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  grep -qxF "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys || echo "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  KEY_INSTALLED=true
fi

set_sshd_option() {
  local key="$1" value="$2"
  if grep -qE "^\s*#?\s*${key}\s+" "$SSHD_CONFIG"; then
    sed -i "s/^\s*#\?\s*${key}\s\+.*/${key} ${value}/" "$SSHD_CONFIG"
  else
    echo "${key} ${value}" >> "$SSHD_CONFIG"
  fi
}

set_sshd_option "Port" "$NEW_SSH_PORT"
set_sshd_option "PermitRootLogin" "prohibit-password"
set_sshd_option "PubkeyAuthentication" "yes"
set_sshd_option "MaxAuthTries" "3"
set_sshd_option "ClientAliveInterval" "300"
set_sshd_option "ClientAliveCountMax" "2"

if $KEY_INSTALLED; then
  set_sshd_option "PasswordAuthentication" "no"
  set_sshd_option "PermitRootLogin" "prohibit-password"
else
  set_sshd_option "PasswordAuthentication" "yes"
fi

sshd -t
systemctl restart ssh

# ------------------------------------------------------------
# FIREWALL (UFW)
# ------------------------------------------------------------
echo "==> Configuring UFW firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${NEW_SSH_PORT}/tcp" comment 'SSH'
ufw allow "${PANEL_PORT}/tcp" comment '3x-ui panel'
# Common Xray inbound ranges — adjust/add per-inbound ports later in the panel as needed
ufw --force enable

# ------------------------------------------------------------
# FAIL2BAN
# ------------------------------------------------------------
echo "==> Configuring fail2ban for SSH..."
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${NEW_SSH_PORT}
maxretry = 5
findtime = 600
bantime = 3600
EOF
systemctl enable fail2ban
systemctl restart fail2ban

# ------------------------------------------------------------
# AUTOMATIC SECURITY UPDATES
# ------------------------------------------------------------
if $ENABLE_AUTO_SECURITY_UPDATES; then
  echo "==> Enabling unattended security updates..."
  dpkg-reconfigure -f noninteractive unattended-upgrades
fi

# ------------------------------------------------------------
# INSTALL 3X-UI
# ------------------------------------------------------------
echo "==> Installing 3x-ui panel..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<< ""

# Generate random admin credentials + secure panel path
ADMIN_USER="admin_$(openssl rand -hex 3)"
ADMIN_PASS="$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)"
PANEL_PATH="/$(openssl rand -hex 6)"

x-ui setting -username "$ADMIN_USER" -password "$ADMIN_PASS" || true
x-ui setting -port "$PANEL_PORT" -webBasePath "$PANEL_PATH" || true
systemctl restart x-ui

SERVER_IP=$(curl -s -4 ifconfig.me || hostname -I | awk '{print $1}')

# ------------------------------------------------------------
# SUMMARY
# ------------------------------------------------------------
cat <<SUMMARY

================= SETUP COMPLETE =================
SSH:
  Port:              ${NEW_SSH_PORT}
  Password login:    $($KEY_INSTALLED && echo "DISABLED (key-only)" || echo "ENABLED (no key was provided)")
  Connect with:      ssh -p ${NEW_SSH_PORT} root@${SERVER_IP}

Firewall (UFW):      active — only SSH (${NEW_SSH_PORT}) and panel (${PANEL_PORT}) open
fail2ban:             active on SSH port ${NEW_SSH_PORT}
Auto security updates: $($ENABLE_AUTO_SECURITY_UPDATES && echo "enabled" || echo "disabled")

3x-ui Panel:
  URL:     http://${SERVER_IP}:${PANEL_PORT}${PANEL_PATH}/
  Username: ${ADMIN_USER}
  Password: ${ADMIN_PASS}

IMPORTANT:
- Save the panel URL/credentials now — shown only once here.
- If password auth is still enabled, add an SSH key and re-run
  with SSH_PUBLIC_KEY set, then disable password auth manually.
- Open the panel and create an inbound (VLESS/VMess/Trojan) for
  your friend, then generate their client config/QR code there.
- Consider putting the panel behind a domain + TLS (Let's Encrypt)
  if it will be used long-term.
====================================================
SUMMARY
