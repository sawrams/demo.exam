# Exam VM Precheck Scripts

These scripts are read-only checks for the KOD 09.02.06-1-2026 VM stands.

Run them inside the Linux/EcoRouter exam VMs:

```bash
bash exam_common_vm_precheck.sh
bash exam_module1_precheck.sh
bash exam_module2_preset_check.sh
bash exam_module3_resource_check.sh
```

If the hostname is not configured yet, force the role:

```bash
ROLE=hq-srv bash exam_module2_preset_check.sh
```

Supported roles:

```text
isp br-fw hq-rtr br-rtr hq-srv br-srv hq-cli br-cli
```

Notes:

- The scripts do not modify files, services, routes, or firewall rules.
- `OK` means the check matched the expected exam state.
- `WARN` means the script could not confirm the state or the item may be completed later.
- `FAIL` means a baseline item expected to be preconfigured was not found.
- Address checks accept the official `10.10.x.x` plan and the sample `192.168.x.x` plan used in the local module notes where those overlap.
