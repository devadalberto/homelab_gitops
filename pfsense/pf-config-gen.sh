#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/common-env.sh
source "${REPO_ROOT}/scripts/common-env.sh"

ENV_FILE=""

usage() {
  cat <<'USAGE'
Usage: pf-config-gen.sh [--env-file PATH]

Render the minimal pfSense config.xml, generate the pfSense_config ISO, and
refresh the ECL FAT USB image under /opt/homelab/pfsense/config.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file|-e)
        if [[ $# -lt 2 ]]; then
          die ${EX_USAGE} "--env-file requires a path argument"
        fi
        ENV_FILE="$2"
        shift 2
        ;;
      --env-file=*|-e=*)
        ENV_FILE="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit ${EX_OK}
        ;;
      *)
        die ${EX_USAGE} "Unknown option: $1"
        ;;
    esac
  done
}

load_environment() {
  if [[ -n ${ENV_FILE} ]]; then
    load_env --env-file "${ENV_FILE}" --required || \
      die ${EX_CONFIG} "Environment file not found: ${ENV_FILE}"
  else
    load_env --silent || true
  fi
}

calculate_prefix_len() {
  if [[ -n ${LAN_PREFIX_LEN:-} ]]; then
    return
  fi
  if [[ -n ${CIDR_BITS:-} ]]; then
    LAN_PREFIX_LEN="${CIDR_BITS}"
    return
  fi
  if [[ -n ${LAN_CIDR:-} && ${LAN_CIDR} == */* ]]; then
    LAN_PREFIX_LEN="${LAN_CIDR##*/}"
    return
  fi
  LAN_PREFIX_LEN=24
}

resolve_defaults() {
  : "${PF_CONFIG_VERSION:=23.09}"
  : "${PF_CONFIG_HOSTNAME:=uranus-pfsense}"
  : "${PF_WAN_INTERFACE:=vtnet0}"
  : "${PF_LAN_INTERFACE:=vtnet1}"
  : "${LAB_DOMAIN_BASE:=labz.home.arpa}"
  : "${LAB_CLUSTER_SUB:=lab-minikube.${LAB_DOMAIN_BASE}}"
  : "${LAN_GW_IP:=10.10.0.1}"
  : "${LAN_DHCP_FROM:=10.10.0.100}"
  : "${LAN_DHCP_TO:=10.10.0.200}"
  : "${DHCP_FROM:=${LAN_DHCP_FROM}}"
  : "${DHCP_TO:=${LAN_DHCP_TO}}"
  : "${METALLB_POOL_START:=10.10.0.240}"
  : "${TRAEFIK_LOCAL_IP:=10.10.0.240}"
  calculate_prefix_len
  : "${CIDR_BITS:=${LAN_PREFIX_LEN}}"
}

render_config() {
  local dest=$1
  local tmp
  tmp=$(mktemp "${dest}.XXXXXX")

  cat >"${tmp}" <<EOF_CONFIG
<?xml version="1.0"?>
<pfsense>
  <version>${PF_CONFIG_VERSION}</version>
  <system>
    <hostname>${PF_CONFIG_HOSTNAME}</hostname>
    <domain>${LAB_DOMAIN_BASE}</domain>
    <dnsserver>1.1.1.1</dnsserver>
    <dnsserver>9.9.9.9</dnsserver>
    <dnsallowoverride>yes</dnsallowoverride>
    <timezone>UTC</timezone>
    <webgui>
      <protocol>https</protocol>
    </webgui>
    <ssh>
      <enable>enabled</enable>
      <port>22</port>
    </ssh>
  </system>
  <interfaces>
    <lan>
      <if>${PF_LAN_INTERFACE}</if>
      <ipaddr>${LAN_GW_IP}</ipaddr>
      <subnet>${CIDR_BITS}</subnet>
      <ipaddrv6>track6</ipaddrv6>
      <descr>LAN</descr>
    </lan>
    <wan>
      <if>${PF_WAN_INTERFACE}</if>
      <ipaddr>dhcp</ipaddr>
      <descr>WAN</descr>
    </wan>
  </interfaces>

  <dhcpd>
    <lan>
      <enable>1</enable>
      <range>
        <from>${DHCP_FROM}</from>
        <to>${DHCP_TO}</to>
      </range>
      <defaultleasetime>7200</defaultleasetime>
      <maxleasetime>86400</maxleasetime>
    </lan>
  </dhcpd>

  <unbound>
    <enable>1</enable>
    <active_interface>lan</active_interface>
    <dnssec>1</dnssec>
    <hideidentity>1</hideidentity>
    <hideversion>1</hideversion>
    <host_domain_type>both</host_domain_type>
    <hosts>
      <host>
        <host>traefik</host>
        <domain>local</domain>
        <ip>${TRAEFIK_LOCAL_IP}</ip>
        <descr>Traefik via home LAN</descr>
      </host>
      <host>
        <host>app</host>
        <domain>${LAB_CLUSTER_SUB}</domain>
        <ip>${METALLB_POOL_START}</ip>
        <descr>Lab application VIP</descr>
      </host>
    </hosts>
  </unbound>

  <nat>
    <outbound>
      <mode>automatic</mode>
    </outbound>
  </nat>

  <filter>
    <rule>
      <type>pass</type>
      <interface>lan</interface>
      <ipprotocol>inet</ipprotocol>
      <descr>Allow LAN to any</descr>
      <src>
        <network>lan</network>
      </src>
      <dst>
        <any/>
      </dst>
      <protocol>any</protocol>
      <disabled/>
    </rule>
  </filter>
</pfsense>
EOF_CONFIG

  chmod 0644 "${tmp}"
  mv "${tmp}" "${dest}"
}

find_iso_command() {
  if command -v genisoimage >/dev/null 2>&1; then
    ISO_CMD=(genisoimage -quiet)
    ISO_TOOL_LABEL="genisoimage"
    return 0
  fi
  if command -v mkisofs >/dev/null 2>&1; then
    ISO_CMD=(mkisofs -quiet)
    ISO_TOOL_LABEL="mkisofs"
    return 0
  fi
  if command -v xorriso >/dev/null 2>&1; then
    ISO_CMD=(xorriso -as mkisofs)
    ISO_TOOL_LABEL="xorriso"
    return 0
  fi
  return 1
}

create_iso() {
  local config_path=$1
  local iso_path=$2
  local staging
  staging=$(mktemp -d)
  local iso_tmp="${iso_path}.tmp"

  cleanup() {
    rm -rf "${staging}" >/dev/null 2>&1 || true
    rm -f "${iso_tmp}" >/dev/null 2>&1 || true
  }
  trap cleanup RETURN

  cp "${config_path}" "${staging}/config.xml"
  mkdir -p "${staging}/conf"
  cp "${config_path}" "${staging}/conf/config.xml"

  if ! find_iso_command; then
    die ${EX_UNAVAILABLE} "Install genisoimage, mkisofs, or xorriso to build the config ISO"
  fi

  log_info "Creating pfSense config ISO with ${ISO_TOOL_LABEL}"
  "${ISO_CMD[@]}" -V "pfSense_config" -o "${iso_tmp}" -J -r "${staging}"
  chmod 0644 "${iso_tmp}"
  mv "${iso_tmp}" "${iso_path}"

  trap - RETURN
  cleanup
}

create_usb_image() {
  local config_path=$1
  local usb_path=$2
  local usb_tmp="${usb_path}.tmp"
  local mount_dir=""
  local need_umount=0

  cleanup_usb() {
    if ((need_umount)); then
      if ((EUID != 0)) && command -v sudo >/dev/null 2>&1; then
        sudo umount "${mount_dir}" >/dev/null 2>&1 || true
      else
        umount "${mount_dir}" >/dev/null 2>&1 || true
      fi
    fi
    if [[ -n ${mount_dir} ]]; then
      rmdir "${mount_dir}" >/dev/null 2>&1 || true
      mount_dir=""
    fi
    rm -f "${usb_tmp}" >/dev/null 2>&1 || true
  }
  trap cleanup_usb RETURN

  local mkfs_cmd
  if command -v mkfs.vfat >/dev/null 2>&1; then
    mkfs_cmd="mkfs.vfat"
  elif command -v mkfs.fat >/dev/null 2>&1; then
    mkfs_cmd="mkfs.fat"
  else
    die ${EX_UNAVAILABLE} "Install mkfs.vfat or mkfs.fat to build the ECL USB image"
  fi

  truncate -s 0 "${usb_tmp}" 2>/dev/null || true
  truncate -s 8M "${usb_tmp}"
  "${mkfs_cmd}" -F 32 -n "ECLCFG" "${usb_tmp}" >/dev/null

  mount_dir=$(mktemp -d)
  local mount_cmd=(mount -o loop "${usb_tmp}" "${mount_dir}")
  local umount_cmd=(umount "${mount_dir}")
  if ((EUID != 0)); then
    if command -v sudo >/dev/null 2>&1; then
      mount_cmd=(sudo mount -o loop "${usb_tmp}" "${mount_dir}")
      umount_cmd=(sudo umount "${mount_dir}")
    else
      die ${EX_UNAVAILABLE} "Root privileges are required to mount ${usb_tmp}"
    fi
  fi

  if "${mount_cmd[@]}" >/dev/null 2>&1; then
    need_umount=1

    mkdir -p "${mount_dir}/config"
    cp "${config_path}" "${mount_dir}/config/config.xml"
    sync

    "${umount_cmd[@]}"
    need_umount=0
    rmdir "${mount_dir}"
    mount_dir=""
  else
    rmdir "${mount_dir}" >/dev/null 2>&1 || true
    mount_dir=""

    if command -v mcopy >/dev/null 2>&1 && command -v mmd >/dev/null 2>&1; then
      log_info "Loopback mount unavailable; using mtools to populate USB image"
      mmd -i "${usb_tmp}" ::config >/dev/null 2>&1 || true
      mcopy -i "${usb_tmp}" "${config_path}" ::config/config.xml >/dev/null
    else
      die ${EX_UNAVAILABLE} "Loopback mount unavailable and mtools not installed"
    fi
  fi

  chmod 0644 "${usb_tmp}"
  mv "${usb_tmp}" "${usb_path}"

  trap - RETURN
  cleanup_usb
}

main() {
  parse_args "$@"
  load_environment
  resolve_defaults

  ensure_dirs "${HOMELAB_PFSENSE_CONFIG_DIR}"

  local config_path="${HOMELAB_PFSENSE_CONFIG_DIR}/config.xml"
  local iso_path="${HOMELAB_PFSENSE_CONFIG_DIR}/pfSense-config.iso"
  local usb_path="${HOMELAB_PFSENSE_CONFIG_DIR}/pfSense-ecl-usb.img"

  render_config "${config_path}"
  log_info "Wrote pfSense config.xml to ${config_path}"

  create_iso "${config_path}" "${iso_path}"
  log_info "Created pfSense config ISO at ${iso_path}"

  create_usb_image "${config_path}" "${usb_path}"
  log_info "Created pfSense ECL USB image at ${usb_path}"

  log_info "pfSense configuration assets ready under ${HOMELAB_PFSENSE_CONFIG_DIR}"
}

main "$@"
