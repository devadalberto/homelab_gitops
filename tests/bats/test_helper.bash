#!/usr/bin/env bash
# shellcheck disable=SC2034

if [[ -z ${REPO_ROOT:-} ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

_common_loaded=0
_preflight_loaded=0

homelab_test_setup() {
  homelab_reset_env
}

homelab_reset_env() {
  local vars=(
    LABZ_DOMAIN LABZ_TRAEFIK_HOST LABZ_NEXTCLOUD_HOST LABZ_JELLYFIN_HOST
    LABZ_METALLB_RANGE METALLB_POOL_START METALLB_POOL_END TRAEFIK_LOCAL_IP
    LAN_CIDR LAN_GW_IP DHCP_FROM DHCP_TO
    PREV_METALLB_START PREV_METALLB_END PREV_TRAEFIK_IP
    NETWORK_ADDR NETWORK_CIDR NETWORK_PREFIX NETWORK_IFACE NETWORK_GW NETWORK_CLASS NETWORK_MTU
  )
  local var
  for var in "${vars[@]}"; do
    unset "${var}"
  done
}

homelab_load_common() {
  if [[ ${_common_loaded} -eq 0 ]]; then
    # shellcheck source=../../scripts/lib/common.sh
    source "${REPO_ROOT}/scripts/lib/common.sh"
    _common_loaded=1
  fi
}

homelab_load_preflight() {
  if [[ ${_preflight_loaded} -eq 0 ]]; then
    local previous_opts
    previous_opts=$(set +o)
    # shellcheck source=../../scripts/preflight_and_bootstrap.sh
    source "${REPO_ROOT}/scripts/preflight_and_bootstrap.sh"
    eval "${previous_opts}"
    _preflight_loaded=1
  fi
}

homelab_load_env_file() {
  local env_file="$1"
  homelab_load_common
  if [[ ! -f ${env_file} ]]; then
    printf 'Environment file not found: %s\n' "${env_file}" >&2
    return 1
  fi
  homelab_reset_env
  load_env "${env_file}"
}

homelab_fixture() {
  local rel_path="$1"
  printf '%s/%s\n' "${REPO_ROOT}/tests/fixtures" "${rel_path}"
}

assert_success() {
  if [[ ${status:-0} -ne 0 ]]; then
    printf 'Expected success but status=%s\nOutput:%s\n' "${status}" "${output:-}" >&2
    return 1
  fi
}

assert_failure() {
  if [[ ${status:-0} -eq 0 ]]; then
    printf 'Expected failure but status=%s\nOutput:%s\n' "${status}" "${output:-}" >&2
    return 1
  fi
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  if [[ "${expected}" != "${actual}" ]]; then
    printf 'Expected %s but found %s\n' "${expected}" "${actual}" >&2
    return 1
  fi
}

assert_not_empty() {
  local value="$1"
  local label="$2"
  if [[ -z ${value} ]]; then
    if [[ -n ${label} ]]; then
      printf 'Expected %s to be set\n' "${label}" >&2
    else
      printf 'Expected value to be set\n' >&2
    fi
    return 1
  fi
}
