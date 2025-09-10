#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env" || source "$ROOT/.env.example"

OUTDIR="${WORK_ROOT}/pfsense/config"
TPL="${ROOT}/pfsense/templates/config.xml.j2"
mkdir -p "$OUTDIR"

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
