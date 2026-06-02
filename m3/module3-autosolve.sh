#!/bin/bash
# KOD 09.02.06-1-2026 Module 3 autosolver for Linux VMs.
# Run locally on each Linux VM:
#   bash module3-autosolve.sh --role hq-srv
#   bash module3-autosolve.sh --role br-srv
#   bash module3-autosolve.sh --role hq-cli
#   bash module3-autosolve.sh --role br-cli
#   bash module3-autosolve.sh --role isp
#
# EcoRouterOS routers are handled by ecorouter-module3.expect.sh from ISP.

set -euo pipefail

PASS="P@ssw0rd"
ROOT_PASS="${ROOT_PASS:-toor}"
DOMAIN="au-team.irpo"
REALM="AU-TEAM.IRPO"
HQ_SRV_IP="10.10.100.2"
HQ_CLI_IP="10.10.200.2"
BR_SRV_IP="10.20.20.2"
BR_CLI_IP="10.20.30.2"
ISP_HQ_IP="172.16.1.1"
ISP_BR_IP="172.16.2.1"
HQ_RTR_IP="172.16.1.2"
BR_RTR_IP="172.16.2.2"
ZBX_PORT="8088"

ROLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 2 ;;
  esac
done

if [ -z "$ROLE" ]; then
  ROLE="$(hostname 2>/dev/null | tr '[:upper:]' '[:lower:]' | cut -d. -f1)"
fi

log() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
die() { echo "[-] $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "Run as root."
}

apt_install() {
  local missing=()
  for pkg in "$@"; do
    rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Installing packages: ${missing[*]}"
    apt-get update || true
    apt-get install -y "${missing[@]}" || warn "Some packages failed to install: ${missing[*]}"
  fi
}

svc_enable_restart() {
  local svc="$1"
  if systemctl list-unit-files "$svc.service" >/dev/null 2>&1 || systemctl status "$svc" >/dev/null 2>&1; then
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl restart "$svc" >/dev/null 2>&1 || systemctl start "$svc" >/dev/null 2>&1 || warn "Could not start $svc"
  else
    warn "Service not found: $svc"
  fi
}

find_iso_root() {
  for d in /media/cdrom /mnt/cdrom /media/Additional /mnt/Additional /media/kib /mnt/kib; do
    [ -d "$d" ] && { echo "$d"; return 0; }
  done
  for dev in /dev/sr0 /dev/sr1; do
    [ -b "$dev" ] || continue
    mkdir -p /media/cdrom
    mount "$dev" /media/cdrom >/dev/null 2>&1 || true
    [ -d /media/cdrom ] && { echo /media/cdrom; return 0; }
  done
  return 1
}

find_iso_file() {
  local pattern="$1"
  local root
  root="$(find_iso_root 2>/dev/null || true)"
  [ -n "$root" ] || return 1
  find "$root" -maxdepth 6 -iname "$pattern" 2>/dev/null | head -n 1
}

trust_ca_file() {
  local ca="$1"
  [ -r "$ca" ] || return 1
  mkdir -p /usr/local/share/ca-certificates /etc/pki/ca-trust/source/anchors
  cp "$ca" /usr/local/share/ca-certificates/au-team-ca.crt 2>/dev/null || true
  cp "$ca" /etc/pki/ca-trust/source/anchors/au-team-ca.crt 2>/dev/null || true
  update-ca-trust >/dev/null 2>&1 || update-ca-certificates >/dev/null 2>&1 || true
}

create_ca_and_certs() {
  apt_install openssl
  mkdir -p /etc/pki/au-team-ca
  chmod 700 /etc/pki/au-team-ca

  if ! openssl list -public-key-algorithms 2>/dev/null | grep -qi gost; then
    warn "OpenSSL GOST provider/engine was not found. Creating RSA CA/certs; replace with GOST if the exam image provides it."
  fi

  if [ ! -f /etc/pki/au-team-ca/ca.key ]; then
    openssl req -x509 -newkey rsa:3072 -nodes \
      -keyout /etc/pki/au-team-ca/ca.key \
      -out /etc/pki/au-team-ca/ca.crt \
      -days 365 \
      -subj "/C=RU/O=IRPO/CN=AU-TEAM Module3 Root CA"
  fi

  for name in web docker mon; do
    cat > "/etc/pki/au-team-ca/${name}.cnf" <<EOF
[req]
distinguished_name = dn
req_extensions = req_ext
prompt = no
[dn]
C = RU
O = IRPO
CN = ${name}.${DOMAIN}
[req_ext]
subjectAltName = DNS:${name}.${DOMAIN}
[x509_ext]
subjectAltName = DNS:${name}.${DOMAIN}
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF
    openssl req -newkey rsa:2048 -nodes \
      -keyout "/etc/pki/au-team-ca/${name}.key" \
      -out "/etc/pki/au-team-ca/${name}.csr" \
      -config "/etc/pki/au-team-ca/${name}.cnf"
    openssl x509 -req \
      -in "/etc/pki/au-team-ca/${name}.csr" \
      -CA /etc/pki/au-team-ca/ca.crt \
      -CAkey /etc/pki/au-team-ca/ca.key \
      -CAcreateserial \
      -out "/etc/pki/au-team-ca/${name}.crt" \
      -days 30 \
      -extensions x509_ext \
      -extfile "/etc/pki/au-team-ca/${name}.cnf"
  done

  trust_ca_file /etc/pki/au-team-ca/ca.crt
  log "CA and 30-day service certificates are in /etc/pki/au-team-ca"
}

add_dns_record() {
  local host="$1" ip="$2" zone=""
  for z in /etc/bind/zone/au-team.irpo.zone /etc/bind/au-team.irpo.zone /var/bind/au-team.irpo.zone; do
    [ -f "$z" ] && zone="$z" && break
  done
  [ -n "$zone" ] || { warn "DNS zone file not found for $host"; return 0; }
  cp "$zone" "$zone.bak.module3.$(date +%s)"
  if grep -Eq "^${host}[[:space:]]+IN[[:space:]]+A" "$zone"; then
    sed -i "s/^${host}[[:space:]]\+IN[[:space:]]\+A[[:space:]]\+.*/${host}    IN  A   ${ip}/" "$zone"
  else
    printf '%-8s IN  A   %s\n' "$host" "$ip" >> "$zone"
  fi
  if have named-checkzone; then
    named-checkzone "$DOMAIN" "$zone" || warn "Zone syntax check failed for $zone"
  fi
  svc_enable_restart bind || true
  svc_enable_restart named || true
}

import_users_csv_if_dc() {
  have samba-tool || { warn "samba-tool missing; skipping domain user import"; return 0; }
  samba-tool domain info 127.0.0.1 >/dev/null 2>&1 || { warn "This host is not responding as Samba DC; skipping users.csv import"; return 0; }

  local csv
  csv="$(find_iso_file users.csv || true)"
  [ -n "$csv" ] || { warn "users.csv not found on Additional.iso"; return 0; }

  log "Importing domain users from $csv"
  samba-tool group add hq >/dev/null 2>&1 || true
  samba-tool group add br >/dev/null 2>&1 || true

  awk 'NR>1 {gsub("\r",""); print}' "$csv" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    user="$(printf '%s\n' "$line" | awk -F'[;,]' '{print $1}' | tr -d '" ')"
    pass="$(printf '%s\n' "$line" | awk -F'[;,]' '{print $2}' | tr -d '" ')"
    given="$(printf '%s\n' "$line" | awk -F'[;,]' '{print $3}' | tr -d '"')"
    surname="$(printf '%s\n' "$line" | awk -F'[;,]' '{print $4}' | tr -d '"')"
    [ -n "$user" ] || continue
    printf '%s\n' "$user" | grep -Eiq '^(login|user|username|samaccountname)$' && continue
    [ -n "$pass" ] || pass="$PASS"
    samba-tool user show "$user" >/dev/null 2>&1 || \
      samba-tool user create "$user" "$pass" --given-name="${given:-$user}" --surname="${surname:-user}" >/dev/null 2>&1 || true
    case "$user" in
      hq*|HQ*) samba-tool group addmembers hq "$user" >/dev/null 2>&1 || true ;;
      br*|BR*) samba-tool group addmembers br "$user" >/dev/null 2>&1 || true ;;
    esac
  done
}

configure_rsyslog_server() {
  apt_install rsyslog logrotate
  mkdir -p /opt
  cat > /etc/rsyslog.d/50-module3-remote.conf <<'EOF'
module(load="imudp")
input(type="imudp" port="514")
module(load="imtcp")
input(type="imtcp" port="514")
$template Module3RemoteLogs,"/opt/%HOSTNAME%/%PROGRAMNAME%.log"
*.warn ?Module3RemoteLogs
& stop
EOF
  cat > /etc/logrotate.d/module3-remote-logs <<'EOF'
/opt/*/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    size 10M
    create 0644 root root
    postrotate
        systemctl reload rsyslog 2>/dev/null || true
    endscript
}
EOF
  svc_enable_restart rsyslog
  logrotate -d /etc/logrotate.d/module3-remote-logs >/dev/null 2>&1 || warn "logrotate dry run failed"
}

configure_rsyslog_client() {
  apt_install rsyslog
  cat > /etc/rsyslog.d/50-module3-client.conf <<EOF
*.warn @${HQ_SRV_IP}:514
EOF
  svc_enable_restart rsyslog
  logger -p user.warn "module3 rsyslog client test from $(hostname -f 2>/dev/null || hostname)"
}

configure_cups_server() {
  apt_install cups cups-client cups-pdf
  mkdir -p /etc/cups
  if [ -f /etc/cups/cupsd.conf ]; then
    cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.bak.module3.$(date +%s)
    sed -i 's/^Listen localhost:631/#Listen localhost:631/' /etc/cups/cupsd.conf
    grep -q '^Port 631' /etc/cups/cupsd.conf || echo 'Port 631' >> /etc/cups/cupsd.conf
    grep -q '^Listen 0.0.0.0:631' /etc/cups/cupsd.conf || echo 'Listen 0.0.0.0:631' >> /etc/cups/cupsd.conf
  fi
  svc_enable_restart cups || svc_enable_restart cupsd || true
  lpadmin -p PDF -v cups-pdf:/ -m CUPS-PDF.ppd -E >/dev/null 2>&1 || \
    lpadmin -p PDF -v cups-pdf:/ -m everywhere -E >/dev/null 2>&1 || warn "Could not create PDF printer automatically"
  lpadmin -d PDF >/dev/null 2>&1 || true
}

configure_cups_client() {
  apt_install cups cups-client
  svc_enable_restart cups || svc_enable_restart cupsd || true
  lpadmin -p HQ-PDF -v "ipp://${HQ_SRV_IP}:631/printers/PDF" -m everywhere -E >/dev/null 2>&1 || warn "Could not add HQ-PDF printer"
  lpadmin -d HQ-PDF >/dev/null 2>&1 || true
}

configure_fail2ban() {
  apt_install fail2ban
  local logpath="/var/log/secure"
  [ -f /var/log/auth.log ] && logpath="/var/log/auth.log"
  mkdir -p /etc/fail2ban
  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 60
findtime = 60
maxretry = 3

[sshd]
enabled = true
port = 2026
logpath = ${logpath}
maxretry = 3
bantime = 60
EOF
  svc_enable_restart fail2ban
}

configure_zabbix_docker() {
  apt_install docker-engine docker-cli docker-compose || true
  svc_enable_restart docker
  have docker || { warn "docker missing; skipping Zabbix"; return 0; }

  docker network create zabbix-net >/dev/null 2>&1 || true
  docker rm -f zabbix-web zabbix-server zabbix-db >/dev/null 2>&1 || true

  docker run -d --name zabbix-db --network zabbix-net \
    -e MYSQL_ROOT_PASSWORD="$PASS" \
    -e MYSQL_DATABASE=zabbix \
    -e MYSQL_USER=zabbix \
    -e MYSQL_PASSWORD="$PASS" \
    mariadb:10.11 >/dev/null 2>&1 || \
  docker run -d --name zabbix-db --network zabbix-net \
    -e MYSQL_ROOT_PASSWORD="$PASS" \
    -e MYSQL_DATABASE=zabbix \
    -e MYSQL_USER=zabbix \
    -e MYSQL_PASSWORD="$PASS" \
    mariadb:latest >/dev/null

  sleep 10
  docker run -d --name zabbix-server --network zabbix-net \
    -e DB_SERVER_HOST=zabbix-db \
    -e MYSQL_DATABASE=zabbix \
    -e MYSQL_USER=zabbix \
    -e MYSQL_PASSWORD="$PASS" \
    -e MYSQL_ROOT_PASSWORD="$PASS" \
    zabbix/zabbix-server-mysql:latest >/dev/null

  docker run -d --name zabbix-web --network zabbix-net \
    -p "${ZBX_PORT}:8080" \
    -e ZBX_SERVER_HOST=zabbix-server \
    -e DB_SERVER_HOST=zabbix-db \
    -e MYSQL_DATABASE=zabbix \
    -e MYSQL_USER=zabbix \
    -e MYSQL_PASSWORD="$PASS" \
    -e MYSQL_ROOT_PASSWORD="$PASS" \
    -e PHP_TZ=Europe/Moscow \
    zabbix/zabbix-web-nginx-mysql:latest >/dev/null

  configure_mon_http_proxy
  log "Zabbix web should be reachable at http://${HQ_SRV_IP}:${ZBX_PORT} and, if Apache proxy loaded, http://mon.${DOMAIN}"
}

configure_mon_http_proxy() {
  local main_conf="" include_line=""
  for f in /etc/httpd2/conf/httpd2.conf /etc/httpd/conf/httpd.conf /etc/apache2/apache2.conf; do
    [ -f "$f" ] && main_conf="$f" && break
  done
  [ -n "$main_conf" ] || { warn "Apache main config not found; use http://mon.${DOMAIN}:${ZBX_PORT} or configure proxy manually."; return 0; }

  local proxy_conf
  proxy_conf="$(dirname "$main_conf")/module3-zabbix-proxy.conf"
  cat > "$proxy_conf" <<EOF
<VirtualHost *:80>
    ServerName mon.${DOMAIN}
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:${ZBX_PORT}/
    ProxyPassReverse / http://127.0.0.1:${ZBX_PORT}/
</VirtualHost>
EOF
  include_line="IncludeOptional ${proxy_conf}"
  grep -Fq "$include_line" "$main_conf" || echo "$include_line" >> "$main_conf"
  if have a2enmod; then
    a2enmod proxy proxy_http >/dev/null 2>&1 || true
  fi
  svc_enable_restart httpd2 || svc_enable_restart httpd || svc_enable_restart apache2 || warn "Could not restart Apache after mon proxy config"
}

configure_zabbix_agent() {
  apt_install zabbix-agent || true
  if [ -f /etc/zabbix/zabbix_agentd.conf ]; then
    sed -i "s/^Server=.*/Server=${HQ_SRV_IP}/" /etc/zabbix/zabbix_agentd.conf
    sed -i "s/^ServerActive=.*/ServerActive=${HQ_SRV_IP}/" /etc/zabbix/zabbix_agentd.conf
    sed -i "s/^Hostname=.*/Hostname=$(hostname -f 2>/dev/null || hostname)/" /etc/zabbix/zabbix_agentd.conf
  fi
  svc_enable_restart zabbix-agent || true
}

configure_ansible_inventory() {
  apt_install ansible sshpass
  mkdir -p /etc/ansible/PC-INFO
  cat > /etc/ansible/hosts <<EOF
[linux]
hq-srv ansible_host=${HQ_SRV_IP} ansible_user=sshuser ansible_port=2026
hq-cli ansible_host=${HQ_CLI_IP} ansible_user=root
br-cli ansible_host=${BR_CLI_IP} ansible_user=root
br-srv ansible_host=${BR_SRV_IP} ansible_user=sshuser ansible_port=2026
EOF
  cat > /etc/ansible/ansible.cfg <<'EOF'
[defaults]
inventory = /etc/ansible/hosts
host_key_checking = False
retry_files_enabled = False
timeout = 10
EOF
  cat > /etc/ansible/playbook.yml <<'EOF'
---
- name: Module3 inventory report
  hosts: linux
  gather_facts: yes
  tasks:
    - name: Save host inventory report
      copy:
        dest: "/etc/ansible/PC-INFO/{{ inventory_hostname }}.yml"
        content: |
          hostname: {{ ansible_fqdn | default(ansible_hostname) }}
          ip: {{ ansible_default_ipv4.address | default('unknown') }}
      delegate_to: localhost
EOF
  log "Ansible inventory and playbook created in /etc/ansible"
  ansible-playbook /etc/ansible/playbook.yml || warn "Ansible run failed; check routes, SSH keys, and users."
}

configure_backup_hq_srv() {
  apt_install sshpass tar gzip mariadb-client || true
  mkdir -p /root/module3-backups
  cat > /root/module3-backup.sh <<EOF
#!/bin/bash
set -e
STAMP=\$(date +%F-%H%M%S)
mkdir -p /root/module3-backups
tar -czf /root/module3-backups/etc-\$STAMP.tar.gz /etc
mysqldump -u root webdb > /root/module3-backups/webdb-\$STAMP.sql 2>/dev/null || true
gzip -f /root/module3-backups/webdb-\$STAMP.sql 2>/dev/null || true
sshpass -p '${ROOT_PASS}' ssh -o StrictHostKeyChecking=no root@${HQ_CLI_IP} 'mkdir -p /backup'
sshpass -p '${ROOT_PASS}' scp -o StrictHostKeyChecking=no /root/module3-backups/etc-\$STAMP.tar.gz root@${HQ_CLI_IP}:/backup/
sshpass -p '${ROOT_PASS}' scp -o StrictHostKeyChecking=no /root/module3-backups/webdb-\$STAMP.sql.gz root@${HQ_CLI_IP}:/backup/ 2>/dev/null || true
EOF
  chmod +x /root/module3-backup.sh
  /root/module3-backup.sh || warn "Backup copy to HQ-CLI failed; verify route and root password."
  grep -q module3-backup /etc/crontab 2>/dev/null || echo "0 3 * * * root /root/module3-backup.sh" >> /etc/crontab

  local kib
  kib="$(find_iso_file 'kiberbackup*management*.rpm' || true)"
  if [ -n "$kib" ]; then
    rpm -Uvh "$kib" || true
    systemctl enable --now kiberbackup-management >/dev/null 2>&1 || true
  else
    warn "Kiber Backup management package not found; fallback tar/mysqldump backup was configured."
  fi
}

configure_backup_hq_cli() {
  mkdir -p /backup
  chmod 777 /backup
  local kib
  kib="$(find_iso_file 'kiberbackup*storage*.rpm' || true)"
  if [ -n "$kib" ]; then
    rpm -Uvh "$kib" || true
    systemctl enable --now kiberbackup-storage-node >/dev/null 2>&1 || true
  else
    warn "Kiber Backup storage-node package not found; /backup directory is ready."
  fi
}

configure_isp_https_proxy() {
  apt_install nginx openssl
  mkdir -p /etc/nginx/ssl /var/www/html
  if [ ! -f /etc/nginx/ssl/au-team-ca.crt ]; then
    create_ca_and_certs
    cp /etc/pki/au-team-ca/ca.crt /etc/nginx/ssl/au-team-ca.crt
    cp /etc/pki/au-team-ca/web.crt /etc/nginx/ssl/web.crt
    cp /etc/pki/au-team-ca/web.key /etc/nginx/ssl/web.key
    cp /etc/pki/au-team-ca/docker.crt /etc/nginx/ssl/docker.crt
    cp /etc/pki/au-team-ca/docker.key /etc/nginx/ssl/docker.key
  fi
  cp /etc/nginx/ssl/au-team-ca.crt /var/www/html/au-team-ca.crt
  printf 'WEB:%s\n' "$(openssl passwd -apr1 "$PASS")" > /etc/nginx/.htpasswd

  mkdir -p /etc/nginx/sites-available.d /etc/nginx/sites-enabled.d /etc/nginx/conf.d
  cat > /etc/nginx/sites-available.d/module3-https.conf <<EOF
server {
    listen 80;
    server_name web.${DOMAIN} docker.${DOMAIN};
    location /au-team-ca.crt { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    server_name web.${DOMAIN};
    ssl_certificate /etc/nginx/ssl/web.crt;
    ssl_certificate_key /etc/nginx/ssl/web.key;
    auth_basic "Restricted Access";
    auth_basic_user_file /etc/nginx/.htpasswd;
    location / { proxy_pass http://${HQ_RTR_IP}:8080; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; }
}
server {
    listen 443 ssl;
    server_name docker.${DOMAIN};
    ssl_certificate /etc/nginx/ssl/docker.crt;
    ssl_certificate_key /etc/nginx/ssl/docker.key;
    location / { proxy_pass http://${BR_RTR_IP}:8080; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; }
}
EOF
  ln -sf /etc/nginx/sites-available.d/module3-https.conf /etc/nginx/sites-enabled.d/module3-https.conf
  nginx -t
  svc_enable_restart nginx
}

configure_hq_cli_trust_isp_ca() {
  apt_install curl ca-certificates || true
  curl -fsS "http://${ISP_HQ_IP}/au-team-ca.crt" -o /tmp/au-team-ca.crt || \
    curl -fsS "http://${ISP_BR_IP}/au-team-ca.crt" -o /tmp/au-team-ca.crt || true
  [ -s /tmp/au-team-ca.crt ] && trust_ca_file /tmp/au-team-ca.crt || warn "Could not fetch ISP CA; copy /etc/nginx/ssl/au-team-ca.crt from ISP to HQ-CLI and trust it."
}

run_hq_srv() {
  create_ca_and_certs
  import_users_csv_if_dc
  add_dns_record mon "$HQ_SRV_IP"
  configure_rsyslog_server
  configure_cups_server
  configure_fail2ban
  configure_zabbix_docker
  configure_zabbix_agent
  configure_backup_hq_srv
}

run_br_srv() {
  import_users_csv_if_dc
  configure_rsyslog_client
  configure_zabbix_agent
  configure_ansible_inventory
}

run_hq_cli() {
  configure_hq_cli_trust_isp_ca
  configure_rsyslog_client
  configure_cups_client
  configure_zabbix_agent
  configure_backup_hq_cli
}

run_br_cli() {
  configure_rsyslog_client
  configure_zabbix_agent
}

run_isp() {
  configure_isp_https_proxy
}

need_root
case "$ROLE" in
  hq-srv|HQ-SRV) run_hq_srv ;;
  br-srv|BR-SRV) run_br_srv ;;
  hq-cli|HQ-CLI) run_hq_cli ;;
  br-cli|BR-CLI) run_br_cli ;;
  isp|ISP) run_isp ;;
  *) die "Unknown role '$ROLE'. Use hq-srv, br-srv, hq-cli, br-cli, or isp." ;;
esac

log "Module 3 autosolve finished for role: $ROLE"
