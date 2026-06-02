#!/usr/bin/env bash
# Read-only Module 3 prerequisite/resource check for KOD 09.02.06-1-2026.
# Run on each VM before starting Module 3: bash exam_module3_resource_check.sh

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

find_iso_roots() {
  local candidates="/media/cdrom /mnt/cdrom /media/Additional /mnt/Additional /media/kib /mnt/kib"
  for d in $candidates; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
  if [ -d /run/media ]; then
    find /run/media -maxdepth 2 -type d 2>/dev/null
  fi
}

find_in_iso() {
  local pattern="$1"
  find_iso_roots | while read -r root; do
    find "$root" -maxdepth 5 -iname "$pattern" 2>/dev/null
  done
}

check_iso_file() {
  local label="$1" pattern="$2"
  local result
  result="$(find_in_iso "$pattern" | head -n 1)"
  if [ "$result" ]; then
    ok "$label found: $result"
  else
    warn "$label not found in common Additional.iso mount paths."
  fi
}

check_service() {
  local svc="$1"
  if have systemctl && systemctl is-active --quiet "$svc" 2>/dev/null; then
    ok "Service active: $svc"
  else
    warn "Service not active or unavailable: $svc"
  fi
}

check_command() {
  local cmd="$1" label="${2:-$1}"
  have "$cmd" && ok "$label command is available." || warn "$label command is missing."
}

check_additional_iso_common() {
  if find_iso_roots | grep -q .; then
    info "Mounted candidate ISO roots:"
    find_iso_roots | sed 's/^/       /'
  else
    warn "No common ISO mount directory found. Mount Additional.iso first if this VM needs it."
  fi

  check_iso_file "users.csv for domain user import" "users.csv"
  check_iso_file "Ansible playbook directory/file" "playbook*"
  check_iso_file "Docker image site_latest" "site_latest*"
  check_iso_file "Docker image mariadb_latest" "mariadb_latest*"
  check_iso_file "Web dump.sql" "dump.sql"
  check_iso_file "Web index.php" "index.php"
  check_iso_file "Kiber Backup management/server package" "kiberbackup*management*.rpm"
  check_iso_file "Kiber Backup storage node package" "kiberbackup*storage*.rpm"
}

check_domain_joined() {
  if have realm; then
    realm list 2>/dev/null | grep -Eiq 'au-team\.irpo|AU-TEAM' && ok "Realm membership includes au-team.irpo." || warn "realm list does not show au-team.irpo."
  elif have net; then
    net ads testjoin >/dev/null 2>&1 && ok "AD join test succeeded." || warn "AD join cannot be confirmed."
  else
    warn "realm/net tools unavailable; cannot confirm domain join."
  fi
}

check_samba_dc() {
  check_command samba-tool "samba-tool"
  if have samba-tool; then
    samba-tool domain info 127.0.0.1 >/dev/null 2>&1 && ok "Samba domain info responds locally." || warn "Samba domain info did not respond locally."
    for u in hquser1 hquser2 hquser3 hquser4 hquser5 bruser1 bruser2 bruser3 bruser4 bruser5; do
      samba-tool user show "$u" >/dev/null 2>&1 && ok "AD user exists: $u" || warn "AD user missing or not yet imported: $u"
    done
    samba-tool group listmembers hq >/dev/null 2>&1 && ok "AD group hq exists." || warn "AD group hq missing."
    samba-tool group listmembers br >/dev/null 2>&1 && ok "AD group br exists." || warn "AD group br missing."
  fi
}

check_hq_srv_module2_state() {
  [ -d /raid ] && ok "/raid exists." || warn "/raid is missing."
  mountpoint -q /raid 2>/dev/null && ok "/raid is mounted." || warn "/raid is not mounted."
  [ -d /raid/nfs ] && ok "/raid/nfs exists." || warn "/raid/nfs is missing."
  check_service nfs-server
  check_service named
  check_service httpd
  check_service mariadb

  if have mysql; then
    mysql -NBe "SHOW DATABASES LIKE 'webdb';" 2>/dev/null | grep -q '^webdb$' && ok "MariaDB database webdb exists." || warn "MariaDB database webdb not found or mysql access failed."
  else
    warn "mysql client missing; cannot check webdb."
  fi

  if [ -r /etc/bind/au-team.irpo.zone ]; then
    grep -q 'mon[[:space:]].*A' /etc/bind/au-team.irpo.zone && ok "DNS zone already has mon A record." || warn "DNS zone lacks mon A record; Module 3 will need it."
  else
    warn "BIND zone file /etc/bind/au-team.irpo.zone is not readable."
  fi
}

check_zabbix_preadded() {
  if have docker; then
    docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -Eiq 'zabbix' && ok "Zabbix container exists." || warn "No Zabbix container found in docker ps -a."
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Eiq 'zabbix' && ok "Zabbix image exists." || warn "No Zabbix image found."
  else
    warn "docker command missing; cannot check pre-added Zabbix container."
  fi
}

check_module3_tools() {
  check_command iptables
  check_command ip
  check_command ss
  check_command logger
  check_command logrotate
  check_command rsyslogd "rsyslogd"
  check_command openssl
  check_command curl
  check_command ansible
  check_command ansible-playbook
}

case "$role" in
  isp)
    check_service nginx
    if [ -r /etc/nginx/.htpasswd ]; then
      grep -q '^WEB:' /etc/nginx/.htpasswd && ok "nginx basic-auth user WEB exists." || warn "/etc/nginx/.htpasswd exists but WEB entry is missing."
    else
      warn "/etc/nginx/.htpasswd missing; Module 2 proxy auth may not be complete."
    fi
    ;;
  hq-rtr|br-rtr|br-fw)
    check_command ipsec
    check_command strongswan
    check_command swanctl
    check_command wg
    check_command vtysh
    if ip tunnel show 2>/dev/null | grep -Eiq 'gre|tun'; then
      ok "Existing GRE/IP tunnel is present before encryption migration."
    else
      warn "Existing GRE/IP tunnel not found."
    fi
    ;;
  hq-srv)
    check_additional_iso_common
    check_hq_srv_module2_state
    check_zabbix_preadded
    check_command cupsctl
    check_command lpadmin
    check_command fail2ban-client
    check_command logrotate
    check_command rsyslogd
    if [ -d /opt ]; then ok "/opt exists for syslog storage."; else fail "/opt is missing."; fi
    ;;
  br-srv)
    check_additional_iso_common
    check_samba_dc
    check_service docker
    check_command docker
    check_command ansible
    [ -d /etc/ansible ] && ok "/etc/ansible exists." || warn "/etc/ansible is missing."
    ;;
  hq-cli|br-cli)
    check_domain_joined
    check_service autofs
    mount | grep -Eq '/mnt/nfs|type nfs' && ok "NFS/autofs mount is active." || warn "NFS/autofs mount is not active yet."
    check_command lpadmin
    check_command yandex-browser
    [ -d /backup ] && ok "/backup exists for Kiber Backup storage node." || warn "/backup is not present yet."
    ;;
  *)
    warn "Unknown role; running generic Module 3 resource checks."
    check_additional_iso_common
    check_module3_tools
    ;;
esac

printf '\nSummary: OK=%s WARN=%s FAIL=%s\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ]
