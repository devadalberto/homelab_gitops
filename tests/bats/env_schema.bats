#!/usr/bin/env bats

load test_helper

setup() {
  homelab_test_setup
  homelab_load_preflight
  homelab_load_env_file "${REPO_ROOT}/.env.example"
}

@test ".env example exports bootstrap essentials" {
  assert_not_empty "${PF_VM_NAME}" "PF_VM_NAME"
  assert_not_empty "${WAN_MODE}" "WAN_MODE"
  assert_not_empty "${PF_WAN_BRIDGE}" "PF_WAN_BRIDGE"
  assert_not_empty "${PF_LAN_BRIDGE}" "PF_LAN_BRIDGE"
  assert_not_empty "${PF_SERIAL_INSTALLER_PATH}" "PF_SERIAL_INSTALLER_PATH"
  assert_not_empty "${LAN_CIDR}" "LAN_CIDR"
  assert_not_empty "${LAN_GW_IP}" "LAN_GW_IP"
  assert_not_empty "${LAN_DHCP_FROM}" "LAN_DHCP_FROM"
  assert_not_empty "${LAN_DHCP_TO}" "LAN_DHCP_TO"
}

@test "LAN DHCP range resides within the LAN CIDR" {
  run ip_in_cidr "${LAN_DHCP_FROM}" "${LAN_CIDR}"
  assert_success
  assert_equal "1" "${output}"

  run ip_in_cidr "${LAN_DHCP_TO}" "${LAN_CIDR}"
  assert_success
  assert_equal "1" "${output}"
}
