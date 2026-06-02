# Module 2: Checks For Tasks Already Done

Use this guide before starting Module 2 to see which tasks may already be completed on the stand.

Run the commands manually on the VM named in each section. No SSH wrapper is included here; connect to the VM/router yourself and run the commands locally.

## Task 1: Samba AD DC On BR-SRV

Run on `BR-SRV`:

```bash
hostname -f
systemctl status samba --no-pager
samba-tool domain info 127.0.0.1
samba-tool user list | grep -E '^(hquser[1-5]|bruser[1-5])$'
samba-tool group listmembers hq
samba-tool group listmembers br
```

Already done if:

- hostname is `br-srv.au-team.irpo`
- `samba` is active
- domain/realm is `au-team.irpo` / `AU-TEAM.IRPO`
- users `hquser1..5` and `bruser1..5` exist
- groups `hq` and `br` contain the correct users

Run on `HQ-CLI` and `BR-CLI`:

```bash
realm list
getent passwd hquser1
getent passwd bruser1
id hquser1
id bruser1
```

Already done if the clients are joined to `au-team.irpo` and domain users resolve.

Check restricted sudo on `HQ-CLI`:

```bash
sudo -l -U hquser1
```

Already done if `hquser1` can run only `cat`, `grep`, and `id` with elevated privileges.

## Task 2: RAID0 On HQ-SRV

Run on `HQ-SRV`:

```bash
lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT
cat /proc/mdstat
mdadm --detail /dev/md0
grep -E '[[:space:]]/raid[[:space:]]' /etc/fstab
df -h /raid
```

Already done if:

- `/dev/md0` exists
- RAID level is `raid0`
- it uses two extra disks
- filesystem is `ext4`
- `/raid` is mounted
- `/etc/fstab` contains an automatic mount entry for `/raid`

## Task 3: NFS On HQ-SRV And Autofs On HQ-CLI/BR-CLI

Run on `HQ-SRV`:

```bash
systemctl status nfs-server --no-pager
grep -v '^#' /etc/exports
exportfs -v
ls -ld /raid/nfs
```

Already done if `/raid/nfs` is exported read/write only for the HQ-CLI and BR-CLI networks.

Run on `HQ-CLI` and `BR-CLI`:

```bash
systemctl status autofs --no-pager
grep -v '^#' /etc/auto.master
cat /etc/auto.nfs
ls /mnt/nfs
ls /mnt/nfs/shared
mount | grep -E 'nfs|/mnt/nfs'
```

Already done if autofs is active and accessing `/mnt/nfs/shared` triggers an NFS mount from `HQ-SRV:/raid/nfs`.

## Task 4: Chrony NTP

Run on `ISP`:

```bash
systemctl status chronyd --no-pager
grep -E '^(pool|server|local|allow|bindaddress)' /etc/chrony.conf
chronyc tracking
chronyc sources -v
```

Already done if:

- `chronyd` is active
- `local stratum 5` is configured
- clients are allowed
- ISP has an upstream NTP source or local stratum fallback

Run on `HQ-SRV`, `HQ-CLI`, `BR-SRV`, `BR-CLI`, `HQ-RTR`, and `BR-RTR`:

```bash
systemctl status chronyd --no-pager
grep -E '^(server|pool)' /etc/chrony.conf
chronyc sources -v
chronyc tracking
```

Already done if each client uses the ISP address as its time source and `chronyc sources -v` shows a selected source, usually marked with `^*`.

## Task 5: Ansible On BR-SRV

Run on `BR-SRV`:

```bash
ansible --version
ls -la /etc/ansible
cat /etc/ansible/hosts
cat /etc/ansible/ansible.cfg
ansible all -m ping
```

Already done if:

- Ansible is installed
- working directory is `/etc/ansible`
- inventory contains `HQ-SRV`, `HQ-CLI`, `HQ-RTR`, `BR-RTR`, and `BR-CLI`
- `ansible all -m ping` returns `pong` without warnings/errors for all targets

## Task 6: Docker Web App On BR-SRV

Run on `BR-SRV`:

```bash
systemctl status docker --no-pager
docker images
docker ps
docker compose ls 2>/dev/null || docker-compose ps
ls -la /opt/docker
cat /opt/docker/docker-compose.yml
curl -I http://localhost:8080
curl http://localhost:8080 | head
```

Already done if:

- Docker is active
- images from `site_latest` and `mariadb_latest` are loaded
- containers include app container `tespapp` and DB container `db`
- compose file uses DB `testdb`, user `test`, password `P@ssw0rd`
- app answers on port `8080`

## Task 7: Apache + MariaDB Web App On HQ-SRV

Run on `HQ-SRV`:

```bash
systemctl status httpd --no-pager
systemctl status mariadb --no-pager
ls -la /var/www/html
grep -R "webdb\|P@ssw0rd\|web" /var/www/html/index.php /var/www/html/config.php 2>/dev/null
mysql -u root -e "SHOW DATABASES LIKE 'webdb';"
mysql -u root -e "SELECT User,Host FROM mysql.user WHERE User='web';"
curl -I http://localhost/
curl http://localhost/ | head
```

Already done if:

- `httpd` and `mariadb` are active
- `index.php` and `images/` are in the Apache web root
- DB `webdb` exists
- DB user `web` exists
- app uses password `P@ssw0rd`
- HTTP on localhost returns a page

## Task 8: Static Port Forwarding On HQ-RTR And BR-RTR

Run on `HQ-RTR`:

```bash
iptables -t nat -S PREROUTING
iptables -S FORWARD
sysctl net.ipv4.ip_forward
```

Already done if:

- forwarding is enabled: `net.ipv4.ip_forward = 1`
- TCP `8080` is forwarded to `HQ-SRV:80`
- TCP `2026` is forwarded to `HQ-SRV:2026`
- matching `FORWARD` accept rules exist

Run on `BR-RTR`:

```bash
iptables -t nat -S PREROUTING
iptables -S FORWARD
sysctl net.ipv4.ip_forward
```

Already done if:

- forwarding is enabled
- TCP `8080` is forwarded to `BR-SRV:8080`
- TCP `2026` is forwarded to `BR-SRV:2026`
- matching `FORWARD` accept rules exist

## Tasks 9-10: Nginx Reverse Proxy And Web Auth On ISP

Run on `ISP`:

```bash
systemctl status nginx --no-pager
nginx -t
grep -R "server_name\|proxy_pass\|auth_basic\|auth_basic_user_file" /etc/nginx
cat /etc/nginx/.htpasswd
curl -I http://web.au-team.irpo/
curl -u WEB:P@ssw0rd -I http://web.au-team.irpo/
curl -I http://docker.au-team.irpo/
```

Already done if:

- `nginx` is active
- `nginx -t` succeeds
- `web.au-team.irpo` proxies to the HQ web app through `HQ-RTR:8080`
- `docker.au-team.irpo` proxies to the Docker app through `BR-RTR:8080`
- `web.au-team.irpo` has basic auth enabled
- `/etc/nginx/.htpasswd` contains user `WEB`
- unauthenticated `web.au-team.irpo` returns `401`
- authenticated `WEB:P@ssw0rd` returns success or redirects to the web app

## Task 11: Yandex Browser On HQ-CLI

Run on `HQ-CLI`:

```bash
yandex-browser --version
rpm -qa | grep -i yandex
which yandex-browser
```

Already done if Yandex Browser is installed and the binary is available.

## Quick Cross-Checks From Client VMs

Run on `HQ-CLI` after DNS/networking are available:

```bash
nslookup web.au-team.irpo
nslookup docker.au-team.irpo
curl -u WEB:P@ssw0rd http://web.au-team.irpo/ | head
curl http://docker.au-team.irpo/ | head
ssh -p 2026 sshuser@hq-srv.au-team.irpo
```

Run on `BR-CLI`:

```bash
nslookup web.au-team.irpo
nslookup docker.au-team.irpo
curl http://docker.au-team.irpo/ | head
ssh -p 2026 sshuser@br-srv.au-team.irpo
```

These checks confirm that the user-facing services are reachable, but the task-specific sections above are better for proving which exact task was already done.
