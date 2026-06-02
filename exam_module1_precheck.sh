#!/usr/bin/env bash
# Read-only Module 1 starting-stand precheck for KOD 09.02.06-1-2026.
# Run on each VM before starting Module 1: bash exam_module1_precheck.sh

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
  if [ "${ROLE:-}" ]; then
    lower "$ROLE"
    return
  fi
  local h
  h="$(hostname 2>/dev/null || true)"
  lower "${h%%.*}"
}

role="$(detect_role)"
[ -n "$role" ] || role="unknown"
info "Detected role: $role"

case "$role" in
  isp|br-fw|hq-rtr|br-rtr|hq-srv|br-srv|hq-cli|br-cli) ;;
  *)
    warn "Could not detect known VM role. Set ROLE=isp|br-fw|hq-rtr|br-rtr|hq-srv|br-srv|hq-cli|br-cli."
    ;;
esac

check_os_hint() {
  if [ ! -r /etc/os-release ]; then
    warn "/etc/os-release is not readable; cannot identify OS."
    return
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  info "OS: ${PRETTY_NAME:-unknown}"

  case "$role" in
    isp|hq-srv|br-srv)
      printf '%s\n' "${PRETTY_NAME:-}" | grep -Eiq 'ALT|server|server 10\.4' \
        && ok "OS string is plausible for ALT Server VM." \
        || warn "Expected ALT Server 10.4 for $role; verify manually."
      ;;
    hq-cli|br-cli)
      printf '%s\n' "${PRETTY_NAME:-}" | grep -Eiq 'ALT|workstation|workstation 10\.4' \
        && ok "OS string is plausible for ALT Workstation VM." \
        || warn "Expected ALT Workstation 10.4 for $role; verify manually."
      ;;
    hq-rtr|br-rtr)
      printf '%s\n' "${PRETTY_NAME:-}" | grep -Eiq 'EcoRouter|ALT' \
        && ok "OS string is plausible for router VM." \
        || warn "Expected EcoRouter for $role; verify manually."
      ;;
    br-fw)
      printf '%s\n' "${PRETTY_NAME:-}" | grep -Eiq 'Xfirewall|Ideco|ALT|Linux' \
        && ok "OS string is plausible for firewall VM." \
        || warn "Expected Xfirewall or Ideco for BR-FW; verify manually."
      ;;
  esac
}

check_resources() {
  local min_mem_mb=0 min_cpu=0 min_root_gb=0
  case "$role" in
    isp) min_mem_mb=850; min_cpu=1; min_root_gb=4 ;;
    br-fw) min_mem_mb=3500; min_cpu=2; min_root_gb=13 ;;
    hq-rtr|br-rtr) min_mem_mb=3500; min_cpu=4; min_root_gb=8 ;;
    hq-srv|br-srv) min_mem_mb=1700; min_cpu=1; min_root_gb=8 ;;
    hq-cli|br-cli) min_mem_mb=1700; min_cpu=2; min_root_gb=13 ;;
  esac

  if [ -r /proc/meminfo ]; then
    local mem_mb
    mem_mb="$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
    info "RAM: ${mem_mb} MiB"
    [ "$min_mem_mb" -eq 0 ] || [ "$mem_mb" -ge "$min_mem_mb" ] \
      && ok "RAM is plausible." \
      || warn "RAM is below expected minimum ${min_mem_mb} MiB."
  fi

  local cpu_count
  cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 0)"
  info "CPU cores: $cpu_count"
  [ "$min_cpu" -eq 0 ] || [ "$cpu_count" -ge "$min_cpu" ] \
    && ok "CPU count is plausible." \
    || warn "CPU count is below expected minimum $min_cpu."

  if have df; then
    local root_gb
    root_gb="$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$2); print $2}')"
    if [ "${root_gb:-0}" -gt 0 ]; then
      info "Root filesystem size: ${root_gb} GiB"
      [ "$min_root_gb" -eq 0 ] || [ "$root_gb" -ge "$min_root_gb" ] \
        && ok "Root filesystem size is plausible." \
        || warn "Root filesystem may be smaller than expected ${min_root_gb} GiB."
    fi
  fi
}

check_interfaces() {
  if ! have ip; then
    fail "ip command is unavailable; cannot check network adapters."
    return
  fi

  local count expected
  count="$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo" {c++} END {print c+0}')"
  expected=1
  case "$role" in
    isp) expected=3 ;;
    br-fw) expected=2 ;;
    hq-rtr|br-rtr) expected=2 ;;
    hq-srv|br-srv|hq-cli|br-cli) expected=1 ;;
  esac

  info "Non-loopback interfaces: $count"
  ip -br link show 2>/dev/null | sed 's/^/       /'

  if [ "$count" -ge "$expected" ]; then
    ok "Network adapter count is at least $expected for $role."
  else
    fail "Only $count network adapter(s) found; expected at least $expected for $role."
  fi
}

check_module1_tools() {
  for cmd in ip ping hostname hostnamectl timedatectl systemctl awk sed grep; do
    have "$cmd" && ok "Command available: $cmd" || warn "Command missing: $cmd"
  done

  case "$role" in
    isp|hq-srv|br-srv|hq-cli|br-cli)
      for cmd in nmcli apt-get useradd passwd chpasswd; do
        have "$cmd" && ok "Command available: $cmd" || warn "Command missing: $cmd"
      done
      ;;
    hq-rtr|br-rtr)
      for cmd in iptables sysctl; do
        have "$cmd" && ok "Command available: $cmd" || warn "Command missing: $cmd"
      done
      have nmcli && ok "nmcli is available." || warn "nmcli is missing; EcoRouter may use another interface for configuration."
      have vtysh && ok "vtysh is available for OSPF checks/config." || warn "vtysh is missing; OSPF may be configured through another router UI/CLI."
      ;;
    br-fw)
      for cmd in iptables sysctl; do
        have "$cmd" && ok "Command available: $cmd" || warn "Command missing: $cmd"
      done
      ;;
  esac
}

check_clean_or_existing_state() {
  local fqdn
  fqdn="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
  info "Current hostname/FQDN: ${fqdn:-unknown}"

  case "$fqdn" in
    *.au-team.irpo) ok "Hostname already uses au-team.irpo domain." ;;
    *)
      warn "Hostname is not yet in au-team.irpo domain; this is expected before Module 1 configuration."
      ;;
  esac

  if have ip; then
    info "Current IPv4 state:"
    ip -br -4 addr show 2>/dev/null | sed 's/^/       /'
    info "Current routes:"
    ip route show 2>/dev/null | sed 's/^/       /'
  fi

  if [ "$role" = "hq-srv" ] || [ "$role" = "br-srv" ]; then
    if getent passwd sshuser >/dev/null 2>&1; then
      warn "sshuser already exists; server may not be in a clean Module 1 starting state."
    else
      ok "sshuser is not present yet."
    fi
  fi

  if [ "$role" = "hq-rtr" ] || [ "$role" = "br-rtr" ]; then
    if getent passwd net_admin >/dev/null 2>&1; then
      warn "net_admin already exists; router may not be in a clean Module 1 starting state."
    else
      ok "net_admin is not present yet."
    fi
  fi

  if have iptables; then
    if iptables -S 2>/dev/null | grep -Eq '^-P (INPUT|FORWARD) DROP|MASQUERADE|DNAT'; then
      warn "iptables already contains restrictive/NAT rules; verify starting snapshot."
    else
      ok "No obvious pre-existing restrictive/NAT iptables rules."
    fi
  fi
}

check_package_sources() {
  case "$role" in
    isp|hq-srv|br-srv|hq-cli|br-cli)
      if have apt-get; then
        ok "apt-get is available for installing Module 1 packages."
      else
        warn "apt-get is missing."
      fi
      if [ -r /etc/apt/sources.list ] || [ -d /etc/apt/sources.list.d ]; then
        ok "APT source configuration exists."
      else
        warn "APT source configuration not found."
      fi
      ;;
  esac
}

check_os_hint
check_resources
check_interfaces
check_module1_tools
check_package_sources
check_clean_or_existing_state

printf '\nSummary: OK=%s WARN=%s FAIL=%s\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ]
