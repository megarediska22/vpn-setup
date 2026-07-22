# OpenVPN Auto-Setup

One-command VPN setup for VPS. Works with Tunnelblick (macOS), OpenVPN Connect (Android/iOS/Windows).

## Quick Start

```bash
ssh root@YOUR_VPS_IP
curl -sL https://raw.githubusercontent.com/megarediska22/vpn-setup/main/setup.sh | sudo bash
```

## What It Does

1. Updates system (Ubuntu/Debian)
2. Installs OpenVPN + easy-rsa
3. Generates all certificates (CA, server, client, DH, TLS-auth)
4. Configures server with AES-256-GCM + SHA256
5. Enables IP forwarding + NAT masquerading
6. Configures firewall (UFW)
7. Creates ready-to-use `client.ovpn` file

## Connecting

### macOS (Tunnelblick)
```bash
brew install --cask tunnelblick
scp root@YOUR_IP:/root/vpn-client/client.ovpn ~/Downloads/
# Open client.ovpn → Tunnelblick imports it → Click Connect
```

### Android / Samsung (OpenVPN Connect)
1. Install OpenVPN Connect from Google Play
2. Transfer `client.ovpn` to your phone
3. OpenVPN Connect → File → Import → select file → Connect

### Windows
1. Install OpenVPN from openvpn.net
2. Copy `client.ovpn` to `C:\Program Files\OpenVPN\config\`
3. Right-click OpenVPN tray → Connect

## Server Management

```bash
systemctl status openvpn@server      # Status
journalctl -u openvpn@server -f      # Live logs
systemctl restart openvpn@server     # Restart
cat /var/log/openvpn-status.log      # Connected clients
```

## Adding More Clients

```bash
cd /etc/openvpn/easy-rsa
./easyrsa --batch build-client-full client2 nopass
```

Then regenerate `client.ovpn` or create a new one with the new client cert.

## Protocol

- Port: 1194/UDP
- Cipher: AES-256-GCM
- Auth: SHA256
- TLS-Auth: Yes (key-direction 1)
- Full tunnel: All traffic routed through VPN
- DNS: 8.8.8.8, 1.1.1.1

## Requirements

- Ubuntu 20.04/22.04/24.04 or Debian 11/12
- Root access
- UDP port 1194 open
