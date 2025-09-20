# pfSense ZTP Lessons Learned

## ISO Image Production
- Always invoke `xorriso -as mkisofs` when rebuilding the pfSense bootstrap media so the image is hybrid and bootable by libvirt.
- Capture the full `xorriso` command in logs or the runbook to make regressions easy to spot; missing the flag silently produces an unusable image.

## Automation Sequencing
- Verify the VM is started before the ZTP script begins its wait loops; otherwise the script exhausts its retries while the domain is still powered off.
- When iterating on ZTP, include an explicit `virsh start` (or equivalent) step prior to invoking the automation to keep the timeline deterministic.

## Bootstrap Health Checks
- Extend the wait budget to cover slow first boots and add a fallback probe to `192.168.1.1`—the pfSense factory default—so the automation can detect when it never pulled the custom config.
- Treat a successful `192.168.1.1` response as a cue to rebuild the USB image and re-run the provisioning workflow.

## NIC Model Policy
- Keep pfSense NICs on `virtio` by default; only switch models when explicitly required and the VM is shut down.
- Document any overrides (such as `PF_FORCE_E1000=true`) so that they are intentional and reversible.

## Updated Runbook for `make up` Failures
1. Rebuild the USB image with `xorriso -as mkisofs` and confirm the command used.
2. Ensure the pfSense domain is running: `sudo virsh list --name | grep pfsense-uranus` and start it if necessary.
3. Capture current wiring: `sudo virsh domiflist pfsense-uranus` and `sudo virsh dumpxml pfsense-uranus` (filter `<interface>` sections).
4. Inspect storage: `sudo virsh domblklist pfsense-uranus` to confirm USB and disk attachments.
5. Check host bridges: `ip -br a | grep -E 'virbr|br0'` to ensure expected links exist.
6. Probe pfSense reachability:
   - `ping -c1 -W1 10.10.0.1` and `curl -kIs --connect-timeout 5 https://10.10.0.1/` for the provisioned address.
   - `ping -c1 -W1 192.168.1.1` as the fallback factory-default probe.
7. If only the fallback address responds, rebuild the USB media and repeat the ZTP run.
8. Collect additional diagnostics with `sudo ./scripts/diag-pfsense.sh` if available.

## Notes
- Keep `.env` aligned with virtio defaults (`PF_FORCE_E1000=false`) and the intended LAN link (`PF_LAN_LINK=bridge:pfsense-lan`).
- Generate the pfSense configuration (`pf-config-gen.sh`) before running ZTP so `/opt/homelab/pfsense/config/config.xml` exists.
