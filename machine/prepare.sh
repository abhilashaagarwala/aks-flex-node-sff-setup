#!/usr/bin/env bash
# Runs ON the edge machine (Azure Linux). Steps 8 and 10.
# FLEX_LAN_CIDR is the LAN the edge machine sits on.
set -euo pipefail
: "${FLEX_LAN_CIDR:?set FLEX_LAN_CIDR, e.g. FLEX_LAN_CIDR=192.168.1.0/24}"

# Step 8: the Flex agent runs kubelet in systemd-nspawn and programs nftables
sudo tdnf install -y nftables systemd-container
sudo systemctl daemon-reload

# Step 10: let pod traffic through. Re-run after the node joins; FORWARD can reset to DROP.
sudo iptables -P FORWARD ACCEPT
sudo iptables -C INPUT -s "$FLEX_LAN_CIDR" -p udp --dport 6081 -m comment --comment "unbounded GENEVE intra-site" -j ACCEPT 2>/dev/null \
  || sudo iptables -I INPUT 1 -s "$FLEX_LAN_CIDR" -p udp --dport 6081 -m comment --comment "unbounded GENEVE intra-site" -j ACCEPT

sudo iptables -S FORWARD | head -1
sudo iptables -S INPUT | head -3
