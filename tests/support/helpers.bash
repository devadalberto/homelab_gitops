#!/usr/bin/env bash

# Helper utilities shared by pfSense smoke tests.

_pf_helpers_saved_path=""
_pf_helpers_bin_dir=""
_pf_helpers_real_ip=""

pf_helpers_use_stub_path() {
  if [[ -z ${BATS_FILE_TMPDIR:-} ]]; then
    printf 'BATS_FILE_TMPDIR must be set before using pf_helpers_use_stub_path\n' >&2
    return 1
  fi
  if [[ -z ${_pf_helpers_saved_path} ]]; then
    _pf_helpers_saved_path="${PATH}"
    _pf_helpers_real_ip=$(command -v ip || true)
    _pf_helpers_bin_dir="${BATS_FILE_TMPDIR}/bin"
    mkdir -p "${_pf_helpers_bin_dir}"
    export PATH="${_pf_helpers_bin_dir}:${PATH}"
  fi
}

pf_helpers_restore_path() {
  if [[ -n ${_pf_helpers_saved_path} ]]; then
    export PATH="${_pf_helpers_saved_path}"
    _pf_helpers_saved_path=""
    _pf_helpers_bin_dir=""
  fi
}

pf_helpers_stub_command() {
  if [[ $# -lt 1 ]]; then
    printf 'pf_helpers_stub_command: command name is required\n' >&2
    return 1
  fi
  pf_helpers_use_stub_path || return 1
  local name=$1
  shift
  local target="${_pf_helpers_bin_dir}/${name}"
  cat "$@" >"${target}"
  chmod +x "${target}"
}

pf_helpers_stub_success() {
  if [[ $# -ne 1 ]]; then
    printf 'pf_helpers_stub_success: command name is required\n' >&2
    return 1
  fi
  local name=$1
  pf_helpers_stub_command "${name}" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
}

pf_helpers_stub_genisoimage() {
  pf_helpers_stub_command genisoimage <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      if [[ $# -lt 2 ]]; then
        echo "genisoimage stub: -o requires a path" >&2
        exit 64
      fi
      output="$2"
      shift 2
      ;;
    -o*)
      output="${1#-o}"
      shift
      ;;
    *)
      shift || true
      ;;
  esac
 done
if [[ -z ${output} ]]; then
  echo "genisoimage stub: output path not provided" >&2
  exit 64
fi
printf 'stub iso\n' >"${output}"
exit 0
SCRIPT
}

pf_helpers_stub_bridge_ip() {
  if [[ $# -ne 1 ]]; then
    printf 'pf_helpers_stub_bridge_ip: bridge name is required\n' >&2
    return 1
  fi
  local bridge=$1
  pf_helpers_use_stub_path || return 1
  local real_ip="${_pf_helpers_real_ip}"
  if [[ -z ${real_ip} ]]; then
    real_ip=$(command -v ip || true)
  fi
  pf_helpers_stub_command ip <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
bridge="${bridge}"
real_ip="${real_ip}"
if [[ "\$1" == "link" && "\$2" == "show" && "\$3" == "dev" && "\$4" == "\${bridge}" ]]; then
  cat <<'OUT'
5: ${bridge}: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noop state UP mode DEFAULT group default qlen 1000
OUT
  exit 0
fi
if [[ "\$1" == "-o" && "\$2" == "link" && "\$3" == "show" && "\$4" == "dev" && "\$5" == "\${bridge}" ]]; then
  echo "5: ${bridge}: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noop state UP mode DEFAULT group default qlen 1000"
  exit 0
fi
if [[ -n "\${real_ip}" ]]; then
  exec "\${real_ip}" "\$@"
fi
echo "ip stub: unsupported arguments: \$*" >&2
exit 1
SCRIPT
}

pf_helpers_write_smoke_env() {
  if [[ $# -ne 2 ]]; then
    printf 'pf_helpers_write_smoke_env: destination path and work root are required\n' >&2
    return 1
  fi
  local dest=$1
  local work_root=$2
  cat <<EOF >"${dest}"
LABZ_DOMAIN=fixture.local
LAB_DOMAIN_BASE=fixture.local
LAB_CLUSTER_SUB=cluster.fixture.local
LAN_CIDR=10.20.0.0/24
LAN_GW_IP=10.20.0.1
DHCP_FROM=10.20.0.50
DHCP_TO=10.20.0.150
METALLB_POOL_START=10.20.0.240
TRAEFIK_LOCAL_IP=10.20.0.240
PF_LAN_BRIDGE=br-test
WAN_MODE=passthrough
WORK_ROOT=${work_root}
EOF
}
