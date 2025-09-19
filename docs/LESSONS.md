# pfSense ZTP Regression and NIC Handling Lessons

## Root Cause
- The pfSense zero-touch provisioning script runs with `set -e`. Post-increment arithmetic expressions like `((idx++))` return `0` on the first iteration, causing the shell to treat the loop body as a failure and abort execution.

## Mitigations
- Replace post-increment operations with safe alternatives such as `((++idx))` or `((idx+=1))` so the arithmetic command always yields a non-zero status during loops.
- Standardize loop patterns (`local idx=0; while (( idx < count )); do ... ((++idx)); done`) to avoid `set -e` surprises.
- Avoid live-switching NIC models on running VMs; only change models when `PF_FORCE_E1000=true` and the domain is shut down. Preserve virtio defaults otherwise.
- Validate LAN wiring via the `PF_LAN_LINK` (`kind:name`) contract and rewire interfaces without altering the NIC model.

## Runbook for `make up` Failures
1. Capture current wiring: `sudo virsh domiflist pfsense-uranus` and `sudo virsh dumpxml pfsense-uranus` (filter `<interface>` sections).
2. Inspect storage: `sudo virsh domblklist pfsense-uranus` to confirm USB and disk attachments.
3. Check host bridges: `ip -br a | grep -E 'virbr|br0'` to ensure expected links exist.
4. Probe pfSense reachability: `ping -c1 -W1 10.10.0.1` and `curl -kIs --connect-timeout 5 https://10.10.0.1/`.
5. If `10.10.0.1` fails but `192.168.1.1` answers, the USB bootstrap likely failed—rebuild media and ensure the VM boots from the new image.
6. Collect additional diagnostics with `sudo ./scripts/diag-pfsense.sh` if available.

## Notes
- Keep `.env` aligned with virtio defaults (`PF_FORCE_E1000=false`) and the intended LAN link (`PF_LAN_LINK=bridge:virbr-lan`).
- Generate the pfSense configuration (`pf-config-gen.sh`) before running ZTP so `/opt/homelab/pfsense/config/config.xml` exists.
