#!/bin/bash
# Run this on ISP. It configures EcoRouterOS HQ-RTR and BR-RTR through SSH.
# It does not copy files to routers.

set -euo pipefail

RTR_USER="${RTR_USER:-net_admin}"
RTR_PASS="${RTR_PASS:-P@ssw0rd}"
HQ_RTR_IP="${HQ_RTR_IP:-172.16.1.2}"
BR_RTR_IP="${BR_RTR_IP:-172.16.2.2}"
HQ_SRV_IP="${HQ_SRV_IP:-10.10.100.2}"

if ! command -v expect >/dev/null 2>&1; then
  apt-get update || true
  apt-get install -y expect
fi

command -v expect >/dev/null 2>&1 || { echo "expect is required"; exit 1; }

run_router() {
  local host="$1"
  local name="$2"
  local local_wan="$3"
  local remote_wan="$4"
  local local_ts="$5"
  local remote_ts="$6"
  local local_match="$7"
  local remote_match="$8"

  expect <<EOF
set timeout 40
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${RTR_USER}@${host}
expect {
  "yes/no" { send "yes\r"; exp_continue }
  "Password:" { send "${RTR_PASS}\r" }
}
expect ">"
send "enable\r"
expect "#"
send "configure\r"
expect "#"

# IPsec IKEv2 profile. Syntax follows EcoRouter IPsec/IKEv2 documentation.
send "crypto-ipsec ike enable\r"
send "crypto-ipsec profile M3-IKE ike-v2\r"
send "mode tunnel\r"
send "ike-phase1\r"
send "proposal aes256-sha256-modp2048\r"
send "auth pre-shared-key P@ssw0rd-Module3-IPsec\r"
send "exit\r"
send "ike-phase2\r"
send "protocol esp\r"
send "proposal aes256-sha256\r"
send "local-ts ${local_ts}\r"
send "remote-ts ${remote_ts}\r"
send "exit\r"
send "exit\r"

send "crypto-map M3-CMAP 10\r"
send "match peer ${remote_wan}\r"
send "set crypto-ipsec profile M3-IKE\r"
send "exit\r"

# Encrypt GRE/WAN endpoint traffic and accept necessary public-side services.
send "filter-map ipv4 M3-ISP-IN 10\r"
send "match any ${local_match} ${remote_match}\r"
send "set crypto-map M3-CMAP peer ${remote_wan}\r"
send "exit\r"
send "filter-map ipv4 M3-ISP-IN 20\r"
send "match udp host ${remote_wan} eq 4500 host ${local_wan} eq 4500\r"
send "set crypto-map M3-CMAP peer ${remote_wan}\r"
send "exit\r"
send "filter-map ipv4 M3-ISP-IN 30\r"
send "match udp any any eq 500\r"
send "set accept\r"
send "exit\r"
send "filter-map ipv4 M3-ISP-IN 40\r"
send "match udp any any eq 4500\r"
send "set accept\r"
send "exit\r"
send "filter-map ipv4 M3-ISP-IN 50\r"
send "match icmp any any\r"
send "set accept\r"
send "exit\r"
send "filter-map ipv4 M3-ISP-IN 60\r"
send "match tcp any any eq 2026\r"
send "set accept\r"
send "exit\r"
send "filter-map ipv4 M3-ISP-IN 70\r"
send "match tcp any any eq 8080\r"
send "set accept\r"
send "exit\r"
send "filter-map ipv4 M3-ISP-IN 80\r"
send "match any any any\r"
send "set drop\r"
send "exit\r"

send "interface ISP\r"
send "set filter-map in M3-ISP-IN 10\r"
send "exit\r"

# Remote syslog to HQ-SRV. If this syntax is not accepted, use '?' in EcoRouterOS and set a warning/all host manually.
send "logging host ${HQ_SRV_IP}\r"
send "logging trap warning\r"

send "end\r"
expect "#"
send "write memory\r"
expect "#"
send "show crypto-ipsec ike connections\r"
expect "#"
send "show crypto-ipsec ike security-associations\r"
expect "#"
send "show running-config | include logging\r"
expect "#"
send "exit\r"
expect eof
EOF
}

echo "===== Configuring HQ-RTR ====="
run_router "$HQ_RTR_IP" "hq-rtr" "$HQ_RTR_IP" "$BR_RTR_IP" "$HQ_RTR_IP" "$BR_RTR_IP" "host ${HQ_RTR_IP}" "host ${BR_RTR_IP}"

echo "===== Configuring BR-RTR ====="
run_router "$BR_RTR_IP" "br-rtr" "$BR_RTR_IP" "$HQ_RTR_IP" "$BR_RTR_IP" "$HQ_RTR_IP" "host ${BR_RTR_IP}" "host ${HQ_RTR_IP}"

echo "===== EcoRouter Module 3 config finished ====="
