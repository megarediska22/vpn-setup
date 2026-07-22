#!/usr/bin/env bash
# ============================================================================
# OpenVPN Auto-Setup — VPS → Working VPN in 1 minute
# Tested on Ubuntu 20.04 / 22.04 / 24.04 and Debian 11/12
# Works with: Tunnelblick (macOS), OpenVPN Connect (Android/iOS/Windows)
# ============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[ERR]${NC} $*"; exit 1; }
step()  { echo -e "\n${CYAN}${BOLD}── $* ──${NC}"; }

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash setup.sh"
grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null || error "Only Ubuntu/Debian supported"

export DEBIAN_FRONTEND=noninteractive

# ── Detect public IP ────────────────────────────────────────────────────────
step "Detecting public IP"
PUBLIC_IP=$(curl -s4 https://ifconfig.me 2>/dev/null || curl -s4 https://api.ipify.org 2>/dev/null || echo "")
[[ -z "$PUBLIC_IP" ]] && error "Cannot detect public IP. Use: sudo bash setup.sh --ip YOUR_IP"
info "Public IP: $PUBLIC_IP"

# ── Update system ───────────────────────────────────────────────────────────
step "Updating system"
apt-get update -qq && apt-get upgrade -y -qq
info "System updated"

# ── Install dependencies ────────────────────────────────────────────────────
step "Installing OpenVPN & easy-rsa"
apt-get install -y -qq openvpn easy-rsa curl
info "Dependencies installed"

# ── Setup PKI ───────────────────────────────────────────────────────────────
step "Generating certificates (this takes ~30 seconds)"
make-cadir /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa

./easyrsa --batch init-pki
./easyrsa --batch build-ca nopass
./easyrsa --batch build-server-full server nopass
./easyrsa --batch build-client-full client nopass
./easyrsa --batch gen-dh
openvpn --genkey secret /etc/openvpn/ta.key
info "Certificates generated"

# ── Server config ───────────────────────────────────────────────────────────
step "Configuring OpenVPN server"
cat > /etc/openvpn/server.conf << EOF
port 1194
proto udp
dev tun

ca   /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key  /etc/openvpn/easy-rsa/pki/private/server.key
dh   /etc/openvpn/easy-rsa/pki/dh.pem
tls-auth /etc/openvpn/ta.key 0

server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"

keepalive 10 120
cipher AES-256-GCM
auth SHA256
user nobody
group nogroup
persist-key
persist-tun
verb 3
explicit-exit-notify 0
EOF
info "Server configured"

# ── IP forwarding ───────────────────────────────────────────────────────────
step "Enabling IP forwarding"
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn.conf
sysctl -p /etc/sysctl.d/99-openvpn.conf >/dev/null
info "IP forwarding enabled"

# ── Firewall ────────────────────────────────────────────────────────────────
step "Configuring firewall"
# OpenVPN port
ufw allow 1194/udp >/dev/null 2>&1 || true

# Disable UFW FORWARD blocking (UFW drops forwarded packets by default)
# This is the critical fix — without it, VPN traffic is silently dropped
if grep -q "DEFAULT_FORWARD_POLICY=\"DROP\"" /etc/default/ufw 2>/dev/null; then
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
fi

# Enable forwarding in ufw sysctl
if ! grep -q "net/ipv4/ip_forward=1" /etc/ufw/sysctl.conf 2>/dev/null; then
    echo "net/ipv4/ip_forward=1" >> /etc/ufw/sysctl.conf
fi

ufw reload >/dev/null 2>&1 || true
info "Firewall configured"

# ── NAT ─────────────────────────────────────────────────────────────────────
step "Configuring NAT"
# Remove old rules if any, then add clean ones
iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j MASQUERADE
info "NAT configured"

# ── Start OpenVPN ───────────────────────────────────────────────────────────
step "Starting OpenVPN"
systemctl enable openvpn@server
systemctl restart openvpn@server
sleep 3

if systemctl is-active --quiet openvpn@server; then
    info "OpenVPN is running"
else
    error "OpenVPN failed to start. Check: journalctl -u openvpn@server -f"
fi

# ── Generate client config ──────────────────────────────────────────────────
step "Generating client configuration"
CA=$(cat /etc/openvpn/easy-rsa/pki/ca.crt)
CERT=$(sed -n "/BEGIN CERTIFICATE/,/END CERTIFICATE/p" /etc/openvpn/easy-rsa/pki/issued/client.crt)
KEY=$(cat /etc/openvpn/easy-rsa/pki/private/client.key)
TLS=$(cat /etc/openvpn/ta.key)

CLIENT_DIR="/root/vpn-client"
mkdir -p "$CLIENT_DIR"

cat > "$CLIENT_DIR/client.ovpn" << OVPF
client
dev tun
proto udp
remote ${PUBLIC_IP} 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
verb 3
key-direction 1

<ca>
${CA}
</ca>

<cert>
${CERT}
</cert>

<key>
${KEY}
</key>

<tls-auth>
${TLS}
</tls-auth>
OVPF

chmod 600 "$CLIENT_DIR/client.ovpn"
info "Client config: $CLIENT_DIR/client.ovpn"

# ── Output ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              OpenVPN Setup Complete!                        ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  ${CYAN}Server:${NC}    ${PUBLIC_IP}:1194/UDP"
echo -e "${BOLD}║${NC}  ${CYAN}Protocol:${NC}  UDP"
echo -e "${BOLD}║${NC}  ${CYAN}Cipher:${NC}    AES-256-GCM + SHA256"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BOLD}How to connect:${NC}"
echo ""
echo -e "${CYAN}macOS:${NC}"
echo "  1. Install Tunnelblick: brew install --cask tunnelblick"
echo "  2. SCP the config:  scp root@${PUBLIC_IP}:/root/vpn-client/client.ovpn ~/Downloads/"
echo "  3. Open client.ovpn → Tunnelblick imports it"
echo "  4. Click Connect"
echo ""
echo -e "${CYAN}Android / Samsung:${NC}"
echo "  1. Install OpenVPN Connect from Google Play"
echo "  2. Transfer client.ovpn to your phone"
echo "  3. OpenVPN Connect → File → Import → select client.ovpn"
echo "  4. Tap Connect"
echo ""
echo -e "${CYAN}Windows:${NC}"
echo "  1. Install OpenVPN from openvpn.net"
echo "  2. Copy client.ovpn to C:\\Program Files\\OpenVPN\\config\\"
echo "  3. Right-click OpenVPN tray icon → Connect"
echo ""
echo -e "${BOLD}Management:${NC}"
echo "  Status:     systemctl status openvpn@server"
echo "  Logs:       journalctl -u openvpn@server -f"
echo "  Restart:    systemctl restart openvpn@server"
echo "  Clients:    cat /var/log/openvpn-status.log"
echo ""
echo -e "${GREEN}${BOLD}VPN is ready! All traffic is encrypted and routed through this server.${NC}"
