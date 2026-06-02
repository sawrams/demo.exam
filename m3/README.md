# Module 3 Autosolve

These scripts are based on the local Module 3 notes, the precheck output in `zalupa.txt`, and the existing `banan-main` script style.

Run the Linux autosolver locally on each VM:

```bash
bash module3-autosolve.sh --role hq-srv
bash module3-autosolve.sh --role br-srv
bash module3-autosolve.sh --role hq-cli
bash module3-autosolve.sh --role br-cli
bash module3-autosolve.sh --role isp
```

Run the EcoRouterOS part from `ISP`:

```bash
bash ecorouter-module3.expect.sh
```

What it covers:

- domain user import from `users.csv` if the current VM is the Samba DC
- local CA and 30-day cert generation
- ISP nginx HTTPS proxy for `web.au-team.irpo` and `docker.au-team.irpo`
- HQ-CLI trust for the generated ISP CA
- EcoRouterOS IPsec/IKEv2 and public-side filter-map commands via SSH from ISP
- rsyslog collector on HQ-SRV and Linux syslog clients
- logrotate for `/opt/*/*.log`
- CUPS PDF printer on HQ-SRV and HQ-CLI client printer
- Zabbix Docker stack on HQ-SRV
- zabbix-agent config on Linux hosts where available
- Ansible inventory/playbook on BR-SRV
- fail2ban for SSH on HQ-SRV
- Kiber Backup package install if RPMs exist, plus a tar/mysqldump fallback backup to `/backup` on HQ-CLI

Important:

- EcoRouterOS command syntax can vary. If `logging host`, `logging trap`, or a `filter-map match` command is rejected, use `?` in the EcoRouter CLI and apply the equivalent setting manually.
- The scripts are idempotent enough for repeat runs, but they do change services and config files. They create timestamped backups for the main DNS/CUPS files where practical.
- OpenSSL GOST support is not guaranteed on the exam image. If the GOST provider/engine is missing, the script creates RSA certificates and prints a warning.
