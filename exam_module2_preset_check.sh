#!/usr/bin/env bash
# Read-only Module 2 stand precheck for KOD 09.02.06-1-2026.
# Run on each VM before starting Module 2: bash exam_module2_preset_check.sh

set -u

PASS=0
WARN=0
FAIL=0

ok() { printf '[OK]   %s\n' "$*"; PASS=$((PASS + 1)); }
warn() { printf '[WARN] %s\n' "$*"; WARN=$((WARN + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '[INFO] %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

detect_role() {
  if [ "${ROLE:-}" ]; then lower "$ROLE"; return; fi
  local h
  h="$(hostname 2>/dev/null || true)"
  lower "${h%%.*}"
}

role="$(detect_role)"
[ -n "$role" ] || role="unknown"
info "Detected role: $role"

ipv4_all() {
  ip -o -4 addr show 2>/dev/null | awk '{print $2" "$4}'
}

has_ip() {
  local regex="$1"
  ipv4_all | grep -Eq "$regex"
}

expect_ip() {
  local label="$1" regex="$2"
  if has_ip "$regex"; then
    ok "$label address is present."
  else
    fail "$label address was not found. Current IPv4: $(ipv4_all | tr '\n' ' ')"
  fi
}

check_default_route() {
  if ip route show default 2>/dev/null | grep -q '^default'; then
    ok "Default route is present."
  else
    warn "Default route is absent."
  fi
}

check_ip_forward() {
  if [ -r /proc/sys/net/ipv4/ip_forward ]; then
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] && ok "IPv4 forwarding is enabled." || fail "IPv4 forwarding is disabled."
  else
    warn "Cannot read /proc/sys/net/ipv4/ip_forward."
  fi
}

check_nat_masquerade() {
  if have iptables; then
    if iptables -t nat -S POSTROUTING 2>/dev/null | grep -q 'MASQUERADE'; then
      ok "NAT MASQUERADE rule is present."
    else
      warn "No NAT MASQUERADE rule found in POSTROUTING."
    fi
  else
    warn "iptables is unavailable; cannot check NAT."
  fi
}

check_service_active() {
  local svc="$1"
  if have systemctl; then
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      ok "Service active: $svc"
      return 0
    fi
    return 1
  fi
  return 1
}

grep_sudoers() {
  local user="$1"
  grep -R "^[[:space:]]*$user[[:space:]].*NOPASSWD" /etc/sudoers /etc/sudoers.d 2>/dev/null
}

check_user() {
  local user="$1" uid_expected="${2:-}"
  if getent passwd "$user" >/dev/null 2>&1; then
    ok "User exists: $user"
    if [ "$uid_expected" ]; then
      uid_actual="$(getent passwd "$user" | awk -F: '{print $3}')"
      [ "$uid_actual" = "$uid_expected" ] && ok "$user UID is $uid_expected." || fail "$user UID is $uid_actual; expected $uid_expected."
    fi
  else
    fail "User missing: $user"
  fi

  if grep_sudoers "$user" >/dev/null; then
    ok "$user has sudo NOPASSWD entry."
  else
    warn "No sudo NOPASSWD entry found for $user."
  fi
}

check_sshd_server() {
  local conf=""
  [ -r /etc/openssh/sshd_config ] && conf="/etc/openssh/sshd_config"
  [ -r /etc/ssh/sshd_config ] && conf="${conf:-/etc/ssh/sshd_config}"

  if [ "$conf" ]; then
    grep -Eiq '^[[:space:]]*Port[[:space:]]+2026([[:space:]]|$)' "$conf" && ok "sshd Port 2026 is configured." || fail "sshd Port 2026 is not configured in $conf."
    grep -Eiq '^[[:space:]]*MaxAuthTries[[:space:]]+2([[:space:]]|$)' "$conf" && ok "sshd MaxAuthTries 2 is configured." || fail "sshd MaxAuthTries 2 is not configured."
    grep -Eiq '^[[:space:]]*Banner[[:space:]]+' "$conf" && ok "sshd Banner is configured." || warn "sshd Banner is not configured."
    grep -Eiq '^[[:space:]]*AllowUsers[[:space:]]+.*sshuser' "$conf" && ok "sshd allows sshuser explicitly." || warn "AllowUsers sshuser not found."
  else
    fail "sshd_config not found in /etc/openssh or /etc/ssh."
  fi

  check_service_active sshd || warn "sshd service is not active according to systemctl."
  if have ss; then
    ss -tln 2>/dev/null | grep -Eq '[:.]2026[[:space:]]' && ok "TCP port 2026 is listening." || warn "TCP port 2026 is not listening."
  fi
}

check_dns_server() {
  check_service_active named || check_service_active bind || warn "named/bind service is not active."
  if have ss; then
    ss -uln 2>/dev/null | grep -Eq '[:.]53[[:space:]]' && ok "DNS UDP/53 is listening." || warn "DNS UDP/53 is not listening."
  fi
  if have dig; then
    dig +short hq-srv.au-team.irpo @127.0.0.1 >/tmp/precheck-dig.$$ 2>/dev/null
    [ -s /tmp/precheck-dig.$$ ] && ok "Local DNS resolves hq-srv.au-team.irpo." || warn "Local DNS did not resolve hq-srv.au-team.irpo."
    rm -f /tmp/precheck-dig.$$
  elif have nslookup; then
    nslookup hq-srv.au-team.irpo 127.0.0.1 >/dev/null 2>&1 && ok "Local DNS resolves hq-srv.au-team.irpo." || warn "Local DNS lookup failed."
  else
    warn "dig/nslookup unavailable; cannot query DNS."
  fi
}

check_dhcp_server() {
  check_service_active dhcpd || check_service_active isc-dhcp-server || warn "DHCP service is not active."
  if [ -r /etc/dhcp/dhcpd.conf ]; then
    grep -Eq '10\.10\.200\.|192\.168\.200\.' /etc/dhcp/dhcpd.conf && ok "DHCP config contains HQ-CLI network." || warn "DHCP config does not mention HQ-CLI network."
    grep -Eq 'au-team\.irpo' /etc/dhcp/dhcpd.conf && ok "DHCP config contains au-team.irpo suffix." || warn "DHCP domain suffix not found."
  else
    warn "/etc/dhcp/dhcpd.conf not readable."
  fi
}

check_tunnel_and_ospf() {
  if ip tunnel show 2>/dev/null | grep -Eiq 'gre|tun'; then
    ok "IP tunnel is present."
  else
    warn "No GRE/IP tunnel found with ip tunnel show."
  fi

  if have vtysh; then
    if vtysh -c 'show ip ospf neighbor' 2>/dev/null | grep -Eiq 'Full|FULL'; then
      ok "OSPF neighbor is Full."
    else
      warn "vtysh did not show a Full OSPF neighbor."
    fi
  elif ip route 2>/dev/null | grep -Eiq 'ospf|zebra|proto 188'; then
    ok "Dynamic routing routes are visible in routing table."
  else
    warn "Cannot confirm OSPF; vtysh unavailable and no obvious OSPF routes."
  fi
}

check_hq_srv_extra_disks() {
  if ! have lsblk; then
    warn "lsblk unavailable; cannot check extra disks."
    return
  fi
  disk_count="$(lsblk -b -dn -o TYPE,SIZE 2>/dev/null | awk '$1=="disk" && $2>=700000000 && $2<=1500000000 {c++} END {print c+0}')"
  info "Approx. 1 GB disk count: $disk_count"
  if [ "$disk_count" -ge 2 ]; then
    ok "At least two 1 GB disks are attached for RAID0 task."
  else
    fail "Fewer than two 1 GB disks are attached for RAID0 task."
  fi
  if [ "$disk_count" -lt 3 ]; then
    warn "Official preset text mentions three additional 1 GB disks; task needs at least two."
  fi
}

check_additional_iso() {
  local dirs="/media/cdrom /mnt/cdrom /media/Additional /mnt/Additional"
  [ "${USER:-}" ] && dirs="$dirs /run/media/$USER"
  local found=0
  for d in $dirs; do
    [ -d "$d" ] || continue
    if find "$d" -maxdepth 3 \( -name 'site_latest*' -o -name 'mariadb_latest*' -o -name 'dump.sql' -o -name 'index.php' \) 2>/dev/null | grep -q .; then
      ok "Additional.iso-like content found under $d."
      found=1
      break
    fi
  done
  [ "$found" -eq 1 ] || warn "Additional.iso content not found in common mount paths."
}

if ! have ip; then
  fail "ip command unavailable; network preset cannot be checked."
else
  case "$role" in
    isp)
      expect_ip "ISP-HQ link 172.16.1.0/28" '172\.16\.1\.'
      expect_ip "ISP-BR link 172.16.2.0/28" '172\.16\.2\.'
      check_default_route
      check_ip_forward
      check_nat_masquerade
      ;;
    hq-rtr)
      expect_ip "HQ-RTR WAN 172.16.1.0/28" '172\.16\.1\.'
      expect_ip "HQ VLAN100 network" '10\.10\.100\.|192\.168\.100\.'
      expect_ip "HQ VLAN200 network" '10\.10\.200\.|192\.168\.200\.'
      expect_ip "HQ VLAN999 network" '10\.10\.30\.|192\.168\.99\.'
      check_default_route
      check_ip_forward
      check_nat_masquerade
      check_user net_admin
      check_tunnel_and_ospf
      check_dhcp_server
      ;;
    br-rtr)
      expect_ip "BR-RTR WAN 172.16.2.0/28" '172\.16\.2\.'
      expect_ip "BR-SRV network" '10\.20\.20\.|192\.168\.20\.'
      expect_ip "BR-CLI network" '10\.20\.30\.'
      check_default_route
      check_ip_forward
      check_nat_masquerade
      check_user net_admin
      check_tunnel_and_ospf
      ;;
    hq-srv)
      expect_ip "HQ-SRV LAN" '10\.10\.100\.|192\.168\.100\.'
      check_default_route
      check_user sshuser 2026
      check_sshd_server
      check_dns_server
      check_hq_srv_extra_disks
      check_additional_iso
      ;;
    br-srv)
      expect_ip "BR-SRV LAN" '10\.20\.20\.|192\.168\.20\.'
      check_default_route
      check_user sshuser 2026
      check_sshd_server
      check_additional_iso
      ;;
    hq-cli)
      expect_ip "HQ-CLI DHCP/LAN" '10\.10\.200\.|192\.168\.200\.'
      check_default_route
      grep -Eq 'au-team\.irpo' /etc/resolv.conf 2>/dev/null && ok "DNS suffix/domain appears in resolv.conf." || warn "DNS suffix/domain not obvious in resolv.conf."
      ;;
    br-cli)
      expect_ip "BR-CLI LAN" '10\.20\.30\.'
      check_default_route
      grep -Eq 'au-team\.irpo' /etc/resolv.conf 2>/dev/null && ok "DNS suffix/domain appears in resolv.conf." || warn "DNS suffix/domain not obvious in resolv.conf."
      ;;
    *)
      warn "Unknown role; only generic network state is printed."
      ipv4_all | sed 's/^/[INFO] /'
      check_default_route
      ;;
  esac
fi

printf '\nSummary: OK=%s WARN=%s FAIL=%s\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ]
