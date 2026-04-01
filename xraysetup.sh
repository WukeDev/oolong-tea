#!/bin/bash
set -e

# ==================
# USER CONFIGURATION
# ==================
WEBSITE="domain.com"          # Your domain
MASK_SITE="www.microsoft.com"      # Reality masking site
SHORT_ID=$(openssl rand -hex 4)      # Your preferred short ID
PORT=443

# ========================
# CLEANUP PREVIOUS INSTALL
# ========================
echo "[+] Stopping and removing old Xray..."
sudo systemctl stop xray || true
sudo systemctl disable xray || true
sudo rm -f /usr/local/bin/xray \
           /etc/systemd/system/xray.service \
           /usr/local/etc/xray/config.json
sudo rm -rf /var/log/xray

# =================
# INSTALL XRAY-CORE
# =================
echo "[+] Installing Xray..."
sudo apt update && sudo apt install -y curl unzip
mkdir -p /usr/local/etc/xray /var/log/xray

curl -L -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o xray.zip -d xray-tmp
sudo install -m 755 xray-tmp/xray /usr/local/bin/xray
rm -rf xray-tmp xray.zip

# ==================
# AUTO-GENERATE KEYS
# ==================
echo "[+] Generating keys..."
XRAY_KEYS=$(/usr/local/bin/xray x25519)

# Ultra-robust extraction: catches "Private key", "PrivateKey", "PublicKey", etc.
XRAY_PRIVATE_KEY=$(echo "$XRAY_KEYS" | grep -iE "Private[ -]?Key" | awk '{print $NF}')
XRAY_PUBLIC_KEY=$(echo "$XRAY_KEYS" | grep -iE "Public[ -]?Key" | awk '{print $NF}')
XRAY_UUID=$(/usr/local/bin/xray uuid)

# Safety Check: Ensure keys are not empty before proceeding
if [[ -z "$XRAY_PRIVATE_KEY" || -z "$XRAY_PUBLIC_KEY" || -z "$XRAY_UUID" ]]; then
    echo "[-] Error: Failed to generate or parse Xray keys."
    echo "Raw output was: $XRAY_KEYS"
    exit 1
fi

# ===========
# XRAY CONFIG
# ===========
echo "[+] Creating Xray config..."
sudo tee /usr/local/etc/xray/config.json > /dev/null <<EOF
{
  "inbounds": [{
    "port": $PORT,
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
      "clients": [
        {
          "id": "$XRAY_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$MASK_SITE:$PORT",
        "xver": 0,
        "serverNames": ["$MASK_SITE"],
        "privateKey": "$XRAY_PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  }],
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "statsUserUplink": false,
        "statsUserDownlink": false
      }
    }
  }
}
EOF

# ===============
# SYSTEMD SERVICE
# ===============
echo "[+] Creating systemd service..."
sudo tee /etc/systemd/system/xray.service > /dev/null <<EOF
[Unit]
Description=Xray Service
After=network.target
StartLimitIntervalSec=30
StartLimitBurst=5

[Service]
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5s
User=root
LogLevelMax=warning

[Install]
WantedBy=multi-user.target
EOF

# ==========
# START XRAY
# ==========
echo "[+] Starting Xray..."
sudo systemctl daemon-reload
sudo systemctl enable --now xray
sleep 3

# ===============
# VERIFY & OUTPUT
# ===============
echo -e "\n[✔] Xray Reality Setup Complete!"
echo -e "\n=== Xray Status ==="
sudo systemctl status xray --no-pager || true

echo -e "\n=== Generated Secrets ==="
echo "UUID: $XRAY_UUID"
echo "Private Key: $XRAY_PRIVATE_KEY"
echo "Public Key: $XRAY_PUBLIC_KEY"

echo -e "\n=== Clash Meta Config ==="
CLASH_YAML="/tmp/clash-${WEBSITE//./-}.yaml"
cat <<EOF | tee $CLASH_YAML
proxies:
  - name: $WEBSITE
    type: vless
    server: $WEBSITE
    port: $PORT
    uuid: $XRAY_UUID
    flow: xtls-rprx-vision
    network: tcp
    tls: true
    udp: true
    servername: $MASK_SITE
    reality-opts:
      public-key: $XRAY_PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: chrome

proxy-groups:
  - name: "Reality"
    type: select
    proxies: ["$WEBSITE"]

rules:
  - MATCH,Reality
EOF

echo -e "\n[ℹ] Clash YAML saved to: $CLASH_YAML"
echo -e "[ℹ] View it with: cat $CLASH_YAML\n"
