#!/usr/bin/env bats

load test_helper

setup() {
  homelab_test_setup
  homelab_load_preflight
}

@test "select_metallb_pool prefers the 240-250 range when available" {
  NETWORK_ADDR=10.10.0.20
  NETWORK_CIDR=10.10.0.0/24
  range_log="${BATS_TEST_TMPDIR}/range_calls"
  range_available() {
    printf '%s-%s\n' "$1" "$2" >>"${range_log}"
    return 0
  }

  select_metallb_pool

  assert_equal "10.10.0.240" "${METALLB_POOL_START}"
  assert_equal "10.10.0.250" "${METALLB_POOL_END}"
  assert_equal "${METALLB_POOL_START}-${METALLB_POOL_END}" "${LABZ_METALLB_RANGE}"
  [[ -f "${range_log}" ]] || fail "range_available was not invoked"
}

@test "select_metallb_pool falls back when preferred range is busy" {
  NETWORK_ADDR=10.10.0.20
  NETWORK_CIDR=10.10.0.0/24
  range_log="${BATS_TEST_TMPDIR}/range_calls"
  call_count=0
  range_available() {
    printf '%s-%s\n' "$1" "$2" >>"${range_log}"
    ((call_count++))
    if (( call_count == 1 )); then
      return 1
    fi
    return 0
  }

  select_metallb_pool

  assert_equal "10.10.0.249" "${METALLB_POOL_START}"
  assert_equal "10.10.0.254" "${METALLB_POOL_END}"
  assert_equal "2" "${call_count}"
}

@test "adapt_address_pools recalculates when previous pool leaves the subnet" {
  NETWORK_ADDR=10.10.0.42
  NETWORK_CIDR=10.10.0.0/24
  PREV_METALLB_START=10.20.0.5
  PREV_METALLB_END=10.20.0.15
  PREV_TRAEFIK_IP=10.20.0.5
  METALLB_POOL_START=""
  METALLB_POOL_END=""
  TRAEFIK_LOCAL_IP=""
  range_available() { return 0; }

  adapt_address_pools

  assert_equal "10.10.0.240" "${METALLB_POOL_START}"
  assert_equal "10.10.0.250" "${METALLB_POOL_END}"
  assert_equal "${METALLB_POOL_START}-${METALLB_POOL_END}" "${LABZ_METALLB_RANGE}"
  assert_equal "${METALLB_POOL_START}" "${TRAEFIK_LOCAL_IP}"
}
