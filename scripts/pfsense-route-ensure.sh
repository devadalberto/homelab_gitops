#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

: "${EX_OK:=0}"
: "${EX_USAGE:=64}"
: "${EX_CONFIG:=78}"
: "${EX_SOFTWARE:=70}"
: "${EX_UNAVAILABLE:=69}"

ENV_FILE_OVERRIDE=""
SSH_HOST_OVERRIDE=""
SSH_USER_OVERRIDE=""
SSH_PORT_OVERRIDE=""
SSH_IDENTITY_OVERRIDE=""
SSH_KNOWN_HOSTS_OVERRIDE=""
SSH_STRICT_OVERRIDE=""
SSH_EXTRA_ARGS=()
DRY_RUN=false

usage() {
  cat <<'USAGE'
Usage: pfsense-route-ensure.sh [OPTIONS]

Ensure the pfSense gateway and static route definitions for the load-balancer network.

Options:
  --env-file PATH              Load environment variables from PATH (default: ./.env when present).
  --host HOST                  Override pfSense SSH host (defaults to PF_SSH_HOST or LAN_GW_IP).
  --user USER                  Override pfSense SSH user (defaults to PF_SSH_USER or 'admin').
  --port PORT                  Override pfSense SSH port (defaults to PF_SSH_PORT or 22).
  --identity PATH              SSH identity file to use when connecting.
  --known-hosts PATH           Custom SSH known_hosts file (defaults to PF_SSH_KNOWN_HOSTS or /dev/null when strict checking disabled).
  --strict-host-key-checking VALUE
                               Set SSH StrictHostKeyChecking (yes|no|ask). Defaults to PF_SSH_STRICT_HOST_KEY_CHECKING or 'no'.
  --ssh-extra-args "ARGS"      Additional arguments appended to the ssh invocation.
  --dry-run                    Print the PHP payload without executing pfSsh.php.
  -h, --help                   Show this help message and exit.
USAGE
}

parse_extra_args() {
  local arg_string=$1
  local -a parsed=()
  if [[ -z ${arg_string} ]]; then
    return
  fi
  eval "parsed=(${arg_string})"
  if ((${#parsed[@]} > 0)); then
    SSH_EXTRA_ARGS+=("${parsed[@]}")
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --env-file | -e)
      if [[ $# -lt 2 ]]; then
        usage >&2
        die "${EX_USAGE}" "--env-file requires a path argument"
      fi
      ENV_FILE_OVERRIDE="$2"
      shift 2
      ;;
    --env-file=* | -e=*)
      ENV_FILE_OVERRIDE="${1#*=}"
      shift
      ;;
    --host)
      if [[ $# -lt 2 ]]; then
        usage >&2
        die "${EX_USAGE}" "--host requires a value"
      fi
      SSH_HOST_OVERRIDE="$2"
      shift 2
      ;;
    --host=*)
      SSH_HOST_OVERRIDE="${1#*=}"
      shift
      ;;
    --user)
      if [[ $# -lt 2 ]]; then
        usage >&2
        die "${EX_USAGE}" "--user requires a value"
      fi
      SSH_USER_OVERRIDE="$2"
      shift 2
      ;;
    --user=*)
      SSH_USER_OVERRIDE="${1#*=}"
      shift
      ;;
    --port)
      if [[ $# -lt 2 ]]; then
        usage >&2
        die "${EX_USAGE}" "--port requires a value"
      fi
      SSH_PORT_OVERRIDE="$2"
      shift 2
      ;;
    --port=*)
      SSH_PORT_OVERRIDE="${1#*=}"
      shift
      ;;
    --identity | -i)
      if [[ $# -lt 2 ]]; then
        usage >&2
        die "${EX_USAGE}" "--identity requires a path"
      fi
      SSH_IDENTITY_OVERRIDE="$2"
      shift 2
      ;;
    --identity=* | -i=*)
      SSH_IDENTITY_OVERRIDE="${1#*=}"
      shift
      ;;
    --known-hosts)
      if [[ $# -lt 2 ]]; then
        usage >&2
        die "${EX_USAGE}" "--known-hosts requires a path"
      fi
      SSH_KNOWN_HOSTS_OVERRIDE="$2"
      shift 2
      ;;
    --known-hosts=*)
      SSH_KNOWN_HOSTS_OVERRIDE="${1#*=}"
      shift
      ;;
    --strict-host-key-checking)
      if [[ $# -lt 2 ]]; then
        usage >&2
        die "${EX_USAGE}" "--strict-host-key-checking requires a value"
      fi
      SSH_STRICT_OVERRIDE="$2"
      shift 2
      ;;
    --strict-host-key-checking=*)
      SSH_STRICT_OVERRIDE="${1#*=}"
      shift
      ;;
    --ssh-extra-args)
      if [[ $# -lt 2 ]]; then
        usage >&2
        die "${EX_USAGE}" "--ssh-extra-args requires an argument string"
      fi
      parse_extra_args "$2"
      shift 2
      ;;
    --ssh-extra-args=*)
      parse_extra_args "${1#*=}"
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h | --help)
      usage
      exit "${EX_OK}"
      ;;
    --)
      shift
      if [[ $# -gt 0 ]]; then
        usage >&2
        die "${EX_USAGE}" "Unexpected positional arguments: $*"
      fi
      ;;
    -*)
      usage >&2
      die "${EX_USAGE}" "Unknown option: $1"
      ;;
    *)
      usage >&2
      die "${EX_USAGE}" "Positional arguments are not supported"
      ;;
    esac
  done
}

build_ssh_command() {
  local host=$1
  local user=$2
  local port=$3
  local identity=$4
  local known_hosts=$5
  local strict=$6
  local -a cmd=(ssh -o BatchMode=yes)

  if [[ -n ${strict} ]]; then
    cmd+=(-o "StrictHostKeyChecking=${strict}")
  else
    cmd+=(-o "StrictHostKeyChecking=no")
  fi

  if [[ -n ${known_hosts} ]]; then
    cmd+=(-o "UserKnownHostsFile=${known_hosts}")
  elif [[ ${strict:-no} == "no" ]]; then
    cmd+=(-o "UserKnownHostsFile=/dev/null")
  fi

  if [[ -n ${port} ]]; then
    cmd+=(-p "${port}")
  fi

  if [[ -n ${identity} ]]; then
    cmd+=(-i "${identity}")
  fi

  if ((${#SSH_EXTRA_ARGS[@]} > 0)); then
    cmd+=("${SSH_EXTRA_ARGS[@]}")
  fi

  cmd+=("${user}@${host}" "/usr/local/sbin/pfSsh.php")
  printf '%s\0' "${cmd[@]}"
}

php_escape_string() {
  printf '%s' "$1" | sed -e "s/\\/\\\\/g" -e "s/'/\'/g"
}

generate_php_payload() {
  local gateway_name=$1
  local gateway_interface=$2
  local gateway_ip=$3
  local gateway_monitor=$4
  local gateway_descr=$5
  local gateway_weight=$6
  local gateway_protocol=$7
  local route_cidr=$8
  local route_descr=$9
  local route_interface=${10:-}

  printf "\$gatewayName = '%s';\n" "$(php_escape_string "${gateway_name}")"
  printf "\$gatewayInterface = '%s';\n" "$(php_escape_string "${gateway_interface}")"
  printf "\$gatewayIp = '%s';\n" "$(php_escape_string "${gateway_ip}")"
  printf "\$gatewayMonitor = '%s';\n" "$(php_escape_string "${gateway_monitor}")"
  printf "\$gatewayDescr = '%s';\n" "$(php_escape_string "${gateway_descr}")"
  printf "\$gatewayWeight = '%s';\n" "$(php_escape_string "${gateway_weight}")"
  printf "\$gatewayProtocol = '%s';\n" "$(php_escape_string "${gateway_protocol}")"
  printf "\$routeCidr = '%s';\n" "$(php_escape_string "${route_cidr}")"
  printf "\$routeDescr = '%s';\n" "$(php_escape_string "${route_descr}")"
  printf "\$routeInterface = '%s';\n" "$(php_escape_string "${route_interface}")"
  cat <<'PHP'
global $config;
require_once('globals.inc');
require_once('config.lib.inc');
require_once('functions.inc');
require_once('interfaces.inc');
require_once('system.inc');

$gatewayChanged = false;
$routeChanged = false;

if (!isset($config['gateways']) || !is_array($config['gateways'])) {
    $config['gateways'] = array();
}
if (!isset($config['gateways']['gateway_item']) || !is_array($config['gateways']['gateway_item'])) {
    $config['gateways']['gateway_item'] = array();
}

$gatewayIndex = null;
foreach ($config['gateways']['gateway_item'] as $idx => $entry) {
    if (isset($entry['name']) && $entry['name'] === $gatewayName) {
        $gatewayIndex = $idx;
        break;
    }
}
if ($gatewayIndex === null) {
    $config['gateways']['gateway_item'][] = array();
    $gatewayIndex = count($config['gateways']['gateway_item']) - 1;
    $gatewayChanged = true;
}

$requiredGatewayFields = array(
    'name' => $gatewayName,
    'interface' => $gatewayInterface,
    'gateway' => $gatewayIp,
);
if (!empty($gatewayProtocol)) {
    $requiredGatewayFields['ipprotocol'] = $gatewayProtocol;
}

foreach ($requiredGatewayFields as $field => $expected) {
    if (!isset($config['gateways']['gateway_item'][$gatewayIndex][$field]) || $config['gateways']['gateway_item'][$gatewayIndex][$field] !== $expected) {
        $config['gateways']['gateway_item'][$gatewayIndex][$field] = $expected;
        $gatewayChanged = true;
    }
}

$optionalGatewayFields = array(
    'monitor' => $gatewayMonitor,
    'descr' => $gatewayDescr,
    'weight' => $gatewayWeight,
);
foreach ($optionalGatewayFields as $field => $expected) {
    if ($expected === '') {
        if (isset($config['gateways']['gateway_item'][$gatewayIndex][$field])) {
            unset($config['gateways']['gateway_item'][$gatewayIndex][$field]);
            $gatewayChanged = true;
        }
    } else {
        if (!isset($config['gateways']['gateway_item'][$gatewayIndex][$field]) || $config['gateways']['gateway_item'][$gatewayIndex][$field] !== $expected) {
            $config['gateways']['gateway_item'][$gatewayIndex][$field] = $expected;
            $gatewayChanged = true;
        }
    }
}

if (!isset($config['staticroutes']) || !is_array($config['staticroutes'])) {
    $config['staticroutes'] = array();
}
if (!isset($config['staticroutes']['route']) || !is_array($config['staticroutes']['route'])) {
    $config['staticroutes']['route'] = array();
}

$routeIndex = null;
foreach ($config['staticroutes']['route'] as $idx => $entry) {
    if (isset($entry['network']) && $entry['network'] === $routeCidr) {
        $routeIndex = $idx;
        break;
    }
}
if ($routeIndex === null) {
    $config['staticroutes']['route'][] = array();
    $routeIndex = count($config['staticroutes']['route']) - 1;
    $routeChanged = true;
}

$requiredRouteFields = array(
    'network' => $routeCidr,
    'gateway' => $gatewayName,
);
foreach ($requiredRouteFields as $field => $expected) {
    if (!isset($config['staticroutes']['route'][$routeIndex][$field]) || $config['staticroutes']['route'][$routeIndex][$field] !== $expected) {
        $config['staticroutes']['route'][$routeIndex][$field] = $expected;
        $routeChanged = true;
    }
}

$optionalRouteFields = array(
    'descr' => $routeDescr,
    'interface' => $routeInterface,
);
foreach ($optionalRouteFields as $field => $expected) {
    if ($expected === '') {
        if (isset($config['staticroutes']['route'][$routeIndex][$field])) {
            unset($config['staticroutes']['route'][$routeIndex][$field]);
            $routeChanged = true;
        }
    } else {
        if (!isset($config['staticroutes']['route'][$routeIndex][$field]) || $config['staticroutes']['route'][$routeIndex][$field] !== $expected) {
            $config['staticroutes']['route'][$routeIndex][$field] = $expected;
            $routeChanged = true;
        }
    }
}

if ($gatewayChanged || $routeChanged) {
    write_config('Ensure homelab load-balancer route');
    if (function_exists('mark_subsystem_dirty')) {
        mark_subsystem_dirty('staticroutes');
    }
    if (function_exists('system_routing_configure')) {
        system_routing_configure();
    } elseif (function_exists('staticroutes_configure')) {
        staticroutes_configure();
    }
    echo "Routing configuration updated. Gateway changed: " . ($gatewayChanged ? 'yes' : 'no') . ", route changed: " . ($routeChanged ? 'yes' : 'no') . "\n";
} else {
    echo "Routing configuration already aligned.\n";
}
PHP
}

main() {
  parse_args "$@"

  local env_file=""
  if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
    env_file=${ENV_FILE_OVERRIDE}
  elif [[ -f "${REPO_ROOT}/.env" ]]; then
    env_file="${REPO_ROOT}/.env"
  elif [[ -f "./.env" ]]; then
    env_file="./.env"
  fi

  if [[ -n ${env_file} ]]; then
    if ! load_env --env-file "${env_file}"; then
      die "${EX_CONFIG}" "Failed to load environment file: ${env_file}"
    fi
  fi

  local route_cidr="${PF_LB_CIDR:-}"
  if [[ -z ${route_cidr} ]]; then
    die "${EX_CONFIG}" "PF_LB_CIDR must be defined in the environment"
  fi

  local gateway_name="${PF_LB_GATEWAY_NAME:-labz_lb_gw}"
  local gateway_interface="${PF_LB_GATEWAY_INTERFACE:-lan}"
  local gateway_ip="${PF_LB_GATEWAY_IP:-}"
  if [[ -z ${gateway_ip} ]]; then
    die "${EX_CONFIG}" "PF_LB_GATEWAY_IP must be defined in the environment"
  fi
  local gateway_monitor="${PF_LB_GATEWAY_MONITOR:-${gateway_ip}}"
  local gateway_descr="${PF_LB_GATEWAY_DESC:-Managed by homelab GitOps (LB gateway)}"
  local gateway_weight="${PF_LB_GATEWAY_WEIGHT:-}"
  local gateway_protocol="${PF_LB_GATEWAY_PROTOCOL:-inet}"

  local route_descr_default="Managed by homelab GitOps static route for ${route_cidr}"
  local route_descr="${PF_LB_ROUTE_DESC:-${route_descr_default}}"
  local route_interface="${PF_LB_ROUTE_INTERFACE:-${gateway_interface}}"

  command -v ssh >/dev/null 2>&1 || die "${EX_UNAVAILABLE}" "ssh command not found"

  local ssh_host="${SSH_HOST_OVERRIDE:-${PF_SSH_HOST:-${LAN_GW_IP:-}}}"
  local ssh_user="${SSH_USER_OVERRIDE:-${PF_SSH_USER:-admin}}"
  local ssh_port="${SSH_PORT_OVERRIDE:-${PF_SSH_PORT:-22}}"
  local ssh_identity="${SSH_IDENTITY_OVERRIDE:-${PF_SSH_IDENTITY:-}}"
  local ssh_known_hosts="${SSH_KNOWN_HOSTS_OVERRIDE:-${PF_SSH_KNOWN_HOSTS:-}}"
  local ssh_strict="${SSH_STRICT_OVERRIDE:-${PF_SSH_STRICT_HOST_KEY_CHECKING:-}}"

  if [[ -z ${ssh_host} ]]; then
    die "${EX_CONFIG}" "PF_SSH_HOST or LAN_GW_IP must be set to reach pfSense"
  fi
  if [[ -z ${ssh_user} ]]; then
    die "${EX_CONFIG}" "PF_SSH_USER must be set (default admin)"
  fi

  log_info "Ensuring pfSense gateway ${gateway_name} (${gateway_ip}) on ${gateway_interface}"
  log_info "Ensuring static route ${route_cidr} via ${gateway_name}"

  local -a payload_args=(
    "${gateway_name}"
    "${gateway_interface}"
    "${gateway_ip}"
    "${gateway_monitor}"
    "${gateway_descr}"
    "${gateway_weight}"
    "${gateway_protocol}"
    "${route_cidr}"
    "${route_descr}"
    "${route_interface}"
  )

  local php_payload
  php_payload=$(generate_php_payload "${payload_args[@]}")

  if [[ ${DRY_RUN} == true ]]; then
    log_info "Dry run enabled; pfSsh.php will not be invoked."
    printf 'exec\n%s\n' "${php_payload}"
    exit "${EX_OK}"
  fi

  local -a ssh_cmd=()
  mapfile -d '' -t ssh_cmd < <(build_ssh_command "${ssh_host}" "${ssh_user}" "${ssh_port}" "${ssh_identity}" "${ssh_known_hosts}" "${ssh_strict}") || true

  if ((${#ssh_cmd[@]} == 0)); then
    die "${EX_SOFTWARE}" "Failed to construct ssh command"
  fi

  log_info "Connecting to pfSense at ${ssh_user}@${ssh_host}:${ssh_port}"

  if ! {
    printf 'exec\n'
    printf '%s\n' "${php_payload}"
  } | "${ssh_cmd[@]}"; then
    die "${EX_SOFTWARE}" "pfSsh.php invocation failed"
  fi
}

main "$@"
