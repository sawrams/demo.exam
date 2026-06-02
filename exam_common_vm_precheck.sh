#!/usr/bin/env bash
# Read-only common VM precheck for KOD 09.02.06-1-2026 exam stands.
# Run on each VM: bash exam_common_vm_precheck.sh

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
  local h short
  h="$(hostname 2>/dev/null || true)"
  short="${h%%.*}"
  lower "$short"
}

role="$(detect_role)"
[ -n "$role" ] || role="unknown"

case "$role" in
  isp|br-fw|hq-rtr|br-rtr|hq-srv|br-srv|hq-cli|br-cli) ;;
  *)
    warn "Could not detect known VM role from hostname. Set ROLE=isp|hq-rtr|br-rtr|hq-srv|br-srv|hq-cli|br-cli|br-fw."
    ;;
esac

info "Detected role: $role"
info "Hostname: $(hostname 2>/dev/null || echo unknown)"
info "Kernel: $(uname -srmo 2>/dev/null || echo unknown)"

if [ "$(id -u)" -eq 0 ]; then
  ok "Script is running as root."
else
  warn "Script is not running as root; some checks may be incomplete."
fi

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  info "OS: ${PRETTY_NAME:-unknown}"
  case "$role" in
    isp|hq-srv|br-srv)
      printf '%s\n' "${PRETTY_NAME:-}" | grep -Eiq 'ALT|Al.t|server|server 10\.4|EcoRouter' \
        && ok "OS looks compatible for $role." \
        || warn "Expected ALT Server 10.4 on $role; verify manually."
      ;;
    hq-cli|br-cli)
      printf '%s\n' "${PRETTY_NAME:-}" | grep -Eiq 'ALT|workstation|workstation 10\.4' \
        && ok "OS looks compatible for $role." \
        || warn "Expected ALT Workstation 10.4 on $role; verify manually."
      ;;
    hq-rtr|br-rtr)
      printf '%s\n' "${PRETTY_NAME:-}" | grep -Eiq 'EcoRouter|ALT' \
        && ok "Router OS string looks compatible for $role." \
        || warn "Expected EcoRouter on $role; verify manually."
      ;;
  esac
else
  warn "/etc/os-release is absent; cannot identify OS."
fi

fqdn="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
case "$role" in
  isp) expected_fqdn="isp.au-team.irpo" ;;
  br-fw) expected_fqdn="br-fw.au-team.irpo" ;;
  hq-rtr) expected_fqdn="hq-rtr.au-team.irpo" ;;
  br-rtr) expected_fqdn="br-rtr.au-team.irpo" ;;
  hq-srv) expected_fqdn="hq-srv.au-team.irpo" ;;
  br-srv) expected_fqdn="br-srv.au-team.irpo" ;;
  hq-cli) expected_fqdn="hq-cli.au-team.irpo" ;;
  br-cli) expected_fqdn="br-cli.au-team.irpo" ;;
  *) expected_fqdn="" ;;
esac

if [ "$expected_fqdn" ]; then
  if [ "$fqdn" = "$expected_fqdn" ]; then
    ok "FQDN is $expected_fqdn."
  else
    warn "FQDN is '$fqdn'; expected '$expected_fqdn' for this role."
  fi
fi

min_mem_mb=0
min_cpu=0
min_root_gb=0
case "$role" in
  isp) min_mem_mb=850; min_cpu=1; min_root_gb=4 ;;
  br-fw) min_mem_mb=3500; min_cpu=2; min_root_gb=13 ;;
  hq-rtr|br-rtr) min_mem_mb=3500; min_cpu=4; min_root_gb=8 ;;
  hq-srv|br-srv) min_mem_mb=1700; min_cpu=1; min_root_gb=8 ;;
  hq-cli|br-cli) min_mem_mb=1700; min_cpu=2; min_root_gb=13 ;;
esac

if [ -r /proc/meminfo ]; then
  mem_mb="$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
  info "RAM: ${mem_mb} MiB"
  if [ "$min_mem_mb" -gt 0 ]; then
    [ "$mem_mb" -ge "$min_mem_mb" ] && ok "RAM is at or above expected minimum." || warn "RAM is below expected minimum ${min_mem_mb} MiB."
  fi
fi

cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 0)"
info "CPU cores: $cpu_count"
if [ "$min_cpu" -gt 0 ]; then
  [ "$cpu_count" -ge "$min_cpu" ] && ok "CPU count is at or above expected minimum." || warn "CPU count is below expected minimum $min_cpu."
fi

if have df; then
  root_gb="$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$2); print $2}')"
  if [ "${root_gb:-0}" -gt 0 ]; then
    info "Root filesystem size: ${root_gb} GiB"
    if [ "$min_root_gb" -gt 0 ]; then
      [ "$root_gb" -ge "$min_root_gb" ] && ok "Root filesystem size is plausible." || warn "Root filesystem may be smaller than expected ${min_root_gb} GiB."
    fi
  fi
fi

for cmd in ip ping ss systemctl nmcli iptables lsblk mount find awk sed grep curl; do
  if have "$cmd"; then
    ok "Command available: $cmd"
  else
    warn "Command missing: $cmd"
  fi
done

if have ip; then
  info "IPv4 addresses:"
  ip -br -4 addr show 2>/dev/null | sed 's/^/       /'
  info "Routes:"
  ip route show 2>/dev/null | sed 's/^/       /'
else
  fail "ip command is unavailable."
fi

if have timedatectl; then
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  if [ "$tz" = "Europe/Moscow" ]; then
    ok "Timezone is Europe/Moscow."
  else
    warn "Timezone is '${tz:-unknown}', expected Europe/Moscow after Module 1 setup."
  fi
fi

if [ -r /etc/resolv.conf ]; then
  info "resolv.conf nameservers:"
  awk '/^nameserver/ {print "       "$0}' /etc/resolv.conf
else
  warn "/etc/resolv.conf is not readable."
fi

if have lsblk; then
  info "Block devices:"
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null | sed 's/^/       /'
fi

printf '\nSummary: OK=%s WARN=%s FAIL=%s\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ]
