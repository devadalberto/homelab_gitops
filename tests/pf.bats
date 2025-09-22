#!/usr/bin/env bats

load 'bats/test_helper'
load 'support/helpers'

PF_TEST_BRIDGE="br-test"
PF_TEST_ENV_FILE=""

setup_file() {
  pf_helpers_use_stub_path
  pf_helpers_stub_genisoimage
  pf_helpers_stub_success virt-install
  pf_helpers_stub_bridge_ip "${PF_TEST_BRIDGE}"
}

teardown_file() {
  pf_helpers_restore_path
}

setup() {
  homelab_test_setup
  PF_TEST_ENV_FILE="${BATS_FILE_TMPDIR}/pf-smoke.env"
  local work_root="${BATS_FILE_TMPDIR}/work"
  mkdir -p "${work_root}"
  pf_helpers_write_smoke_env "${PF_TEST_ENV_FILE}" "${work_root}"
  export PF_TEST_ENV_FILE
}

@test "doctor command reports success" {
  run ./scripts/doctor.sh --env-file "${PF_TEST_ENV_FILE}"
  assert_success
  [[ "${output}" == *"Doctor OK"* ]]
}

@test "net.ensure validates LAN bridge" {
  run env NET_CREATE=0 ./scripts/net-ensure.sh --env-file "${PF_TEST_ENV_FILE}"
  assert_success
  [[ "${output}" == *"Ready bridges: ${PF_TEST_BRIDGE}"* ]]
}

@test "pf-config generates config and ISO artifacts" {
  local output_dir="${BATS_TEST_TMPDIR}/pf-config"
  mkdir -p "${output_dir}"

  run ./pfsense/pf-config-gen.sh --env-file "${PF_TEST_ENV_FILE}" --output-dir "${output_dir}"
  assert_success

  local config_path="${output_dir}/config.xml"
  [[ -f "${config_path}" ]]

  local iso_path
  iso_path=$(find "${output_dir}" -maxdepth 1 -name 'pfSense-config-*.iso' -type f | head -n 1)
  [[ -n "${iso_path}" ]]
  [[ -f "${iso_path}" ]]

  [[ -L "${output_dir}/pfSense-config-latest.iso" ]]
  [[ -L "${output_dir}/pfSense-config.iso" ]]

  local latest_target iso_target
  latest_target=$(readlink -f "${output_dir}/pfSense-config-latest.iso")
  iso_target=$(readlink -f "${iso_path}")
  [[ "${latest_target}" == "${iso_target}" ]]
}
