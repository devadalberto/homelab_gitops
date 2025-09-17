#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env" || source "$ROOT/.env.example"

OUTDIR="${WORK_ROOT}/pfsense/config"
TPL="${ROOT}/pfsense/templates/config.xml.j2"
ISO_LABEL="pfSense_config"
ISO_STAGING="${OUTDIR}/iso-root"
CONFIG_ISO="${OUTDIR}/pfSense-config.iso"
mkdir -p "$OUTDIR"
trap 'rm -rf "${ISO_STAGING}"' EXIT
rm -rf "${ISO_STAGING}"

python3 - "$METALLB_POOL_START" > "${OUTDIR}/_vips.env" <<'PY'
import sys, ipaddress
start = ipaddress.ip_address(sys.argv[1])
vip = dict(VIP_APP=str(start),
           VIP_GRAFANA=str(start+1),
           VIP_PROM=str(start+2),
           VIP_ALERT=str(start+3),
           VIP_AWX=str(start+4))
for k,v in vip.items():
    print(f"{k}={v}")
PY
source "${OUTDIR}/_vips.env"

python3 - "$TPL" "$OUTDIR/config.xml" <<'PY'
import os, sys
tpl_path, out_path = sys.argv[1], sys.argv[2]
tpl = open(tpl_path).read()
env = os.environ
for k in ["LAB_DOMAIN_BASE","LAB_CLUSTER_SUB","LAN_GW_IP","LAN_DHCP_FROM","LAN_DHCP_TO",
          "METALLB_POOL_START","TRAEFIK_LOCAL_IP","VIP_GRAFANA","VIP_PROM","VIP_ALERT","VIP_AWX"]:
    tpl = tpl.replace("{{ "+k+" }}", env.get(k,""))
open(out_path,"w").write(tpl)
print(out_path)
PY

echo "[OK] Generated pfSense config at ${OUTDIR}/config.xml"

mkdir -p "${ISO_STAGING}/conf"
cp "${OUTDIR}/config.xml" "${ISO_STAGING}/config.xml"
cp "${OUTDIR}/config.xml" "${ISO_STAGING}/conf/config.xml"

ISO_CMD="$(command -v genisoimage || command -v mkisofs || true)"
if [[ -z "${ISO_CMD}" ]]; then
  echo "[ERR] Neither 'genisoimage' nor 'mkisofs' is installed; cannot package config ISO." >&2
  exit 1
fi

"${ISO_CMD}" -quiet -V "${ISO_LABEL}" -o "${CONFIG_ISO}" -J -r "${ISO_STAGING}"

echo "[OK] Packaged pfSense config ISO at ${CONFIG_ISO} (label ${ISO_LABEL})"
