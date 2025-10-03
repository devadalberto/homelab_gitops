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
Usage: dns-pfsense.sh [OPTIONS]

Create or update pfSense DNS Resolver host overrides for LABZ hosts.

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
  # Use shell parsing semantics to honor quoted arguments.
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

php_escape_string() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\'/\\\'}
  printf '%s' "$value"
}

declare -a OVERRIDE_KEYS=()
declare -A OVERRIDE_HOST=()
declare -A OVERRIDE_DOMAIN=()
declare -A OVERRIDE_DESC=()

add_override() {
  local var_name=$1
  local fqdn=$2
  local normalized=${fqdn%.}
  if [[ -z ${normalized} ]]; then
    return
  fi
  local host=""
  local domain=""
  if [[ ${normalized} == *.* ]]; then
    host=${normalized%%.*}
    domain=${normalized#*.}
  else
    host=${normalized}
    if [[ -n ${LAB_DOMAIN_BASE:-} ]]; then
      domain=${LAB_DOMAIN_BASE}
      normalized="${host}.${domain}"
    else
      log_warn "Skipping ${var_name}: unable to derive domain for '${fqdn}'"
      return
    fi
  fi
  host=${host,,}
  domain=${domain,,}
  domain=${domain#.}
  domain=${domain%.}
  if [[ -z ${host} || -z ${domain} ]]; then
    log_warn "Skipping ${var_name}: invalid hostname '${fqdn}'"
    return
  fi
  local key="${host}.${domain}"
  if [[ -z ${OVERRIDE_HOST[$key]:-} ]]; then
    OVERRIDE_KEYS+=("${key}")
    OVERRIDE_HOST["${key}"]=${host}
    OVERRIDE_DOMAIN["${key}"]=${domain}
    OVERRIDE_DESC["${key}"]="Managed by homelab GitOps (${normalized})"
  else
    OVERRIDE_DESC["${key}"]+="; ${normalized}"
  fi
}

collect_overrides() {
  local var_name
  while IFS= read -r var_name; do
    if [[ ${var_name} == LABZ_*_HOST ]]; then
      local value=${!var_name:-}
      if [[ -n ${value} ]]; then
        add_override "${var_name}" "${value}"
      fi
    fi
  done < <(compgen -v | sort)
}

generate_php_payload() {
  local target_ip=$1
  printf "\$target_ip = '%s';\n" "$(php_escape_string "${target_ip}")"
  cat <<'PHP_SNIPPET'
if (!isset($config['unbound']) || !is_array($config['unbound'])) {
    $config['unbound'] = array();
}
if (!isset($config['unbound']['hosts']) || !is_array($config['unbound']['hosts'])) {
    $config['unbound']['hosts'] = array();
}
$entries = array(
PHP_SNIPPET
  local first=1
  local key host domain descr
  for key in "${OVERRIDE_KEYS[@]}"; do
    host=${OVERRIDE_HOST[$key]}
    domain=${OVERRIDE_DOMAIN[$key]}
    descr=${OVERRIDE_DESC[$key]}
    if ((first)); then
      first=0
    else
      printf ",\n"
    fi
    printf "    array('host' => '%s', 'domain' => '%s', 'ip' => \$target_ip, 'descr' => '%s')" \
      "$(php_escape_string "${host}")" \
      "$(php_escape_string "${domain}")" \
      "$(php_escape_string "${descr}")"
  done
  printf "\n);\n"
  cat <<'PHP_SNIPPET'
$changes = 0;
foreach ($entries as $entry) {
    $found = false;
    foreach ($config['unbound']['hosts'] as $idx => $existing) {
        if (isset($existing['host'], $existing['domain']) && $existing['host'] === $entry['host'] && $existing['domain'] === $entry['domain']) {
            $needsUpdate = false;
            if (!isset($existing['ip']) || $existing['ip'] !== $entry['ip']) {
                $config['unbound']['hosts'][$idx]['ip'] = $entry['ip'];
                $needsUpdate = true;
            }
            if (!isset($existing['descr']) || $existing['descr'] !== $entry['descr']) {
                $config['unbound']['hosts'][$idx]['descr'] = $entry['descr'];
                $needsUpdate = true;
            }
            if ($needsUpdate) {
                $changes++;
            }
            $found = true;
            break;
        }
    }
    if (!$found) {
        $config['unbound']['hosts'][] = $entry;
        $changes++;
    }
}
if ($changes > 0) {
    write_config('Update homelab DNS host overrides');
    if (function_exists('services_unbound_configure')) {
        services_unbound_configure();
    } elseif (function_exists('services_dnsmasq_configure')) {
        services_dnsmasq_configure();
    }
    echo "Updated {$changes} host override entries.\n";
} else {
    echo "Host overrides already up to date.\n";
}
PHP_SNIPPET
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

  local lb_ip="${TRAEFIK_LOCAL_IP:-}"
  if [[ -z ${lb_ip} && -n ${LABZ_TRAEFIK_IP:-} ]]; then
    lb_ip="${LABZ_TRAEFIK_IP}"
  fi
  if [[ -z ${lb_ip} ]]; then
    die "${EX_CONFIG}" "TRAEFIK_LOCAL_IP (or LABZ_TRAEFIK_IP) must be set to the Traefik load-balancer IP"
  fi

  collect_overrides
  if ((${#OVERRIDE_KEYS[@]} == 0)); then
    log_warn "No LABZ_*_HOST values found in the environment; nothing to configure."
    exit "${EX_OK}"
  fi

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

  local php_payload
  php_payload=$(generate_php_payload "${lb_ip}")

  if [[ ${DRY_RUN} == true ]]; then
    log_info "Dry run enabled; pfSsh.php will not be invoked."
    printf 'exec\n%s\n' "${php_payload}"
    exit "${EX_OK}"
  fi

  log_info "Updating pfSense host overrides via ssh ${ssh_user}@${ssh_host}:${ssh_port}"
  log_debug "Applying overrides for keys: ${OVERRIDE_KEYS[*]}"

  local -a ssh_cmd=()
  mapfile -d '' -t ssh_cmd < <(build_ssh_command "${ssh_host}" "${ssh_user}" "${ssh_port}" "${ssh_identity}" "${ssh_known_hosts}" "${ssh_strict}") || true

  if ((${#ssh_cmd[@]} == 0)); then
    die "${EX_SOFTWARE}" "Failed to construct ssh command"
  fi

  if ! {
    printf 'exec\n'
    printf '%s\n' "${php_payload}"
  } | "${ssh_cmd[@]}"; then
    die "${EX_SOFTWARE}" "pfSsh.php invocation failed"
  fi
}

main "$@"
