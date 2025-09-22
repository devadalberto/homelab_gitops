#!/usr/bin/env bats

load test_helper

setup() {
  homelab_test_setup
  homelab_load_preflight
  homelab_load_env_file "${REPO_ROOT}/.env.example"
}

@test ".env example exports bootstrap essentials" {
  assert_not_empty "${LABZ_DOMAIN}" "LABZ_DOMAIN"
  assert_not_empty "${LABZ_MINIKUBE_PROFILE}" "LABZ_MINIKUBE_PROFILE"
  assert_not_empty "${LAN_CIDR}" "LAN_CIDR"
  assert_not_empty "${PF_LAN_BRIDGE}" "PF_LAN_BRIDGE"
  assert_not_empty "${METALLB_POOL_START}" "METALLB_POOL_START"
  assert_not_empty "${METALLB_POOL_END}" "METALLB_POOL_END"
  assert_not_empty "${LABZ_METALLB_RANGE}" "LABZ_METALLB_RANGE"
  assert_not_empty "${TRAEFIK_LOCAL_IP}" "TRAEFIK_LOCAL_IP"
  assert_equal "${METALLB_POOL_START}-${METALLB_POOL_END}" "${LABZ_METALLB_RANGE}"
}

@test "MetalLB start/end reside within the LAN CIDR" {
  run ip_in_cidr "${METALLB_POOL_START}" "${LAN_CIDR}"
  assert_success
  assert_equal "1" "${output}" 

  run ip_in_cidr "${METALLB_POOL_END}" "${LAN_CIDR}"
  assert_success
  assert_equal "1" "${output}"

  run ip_between "${TRAEFIK_LOCAL_IP}" "${METALLB_POOL_START}" "${METALLB_POOL_END}"
  assert_success
  assert_equal "1" "${output}"
}
