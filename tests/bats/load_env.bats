#!/usr/bin/env bats

load test_helper

setup() {
  homelab_test_setup
  homelab_load_common
  LOAD_ENV_ARGS=()
}

@test "load_env loads env from positional path argument" {
  local env_file_rel="tests/fixtures/envs/basic.env"
  pushd "${REPO_ROOT}" >/dev/null
  set -- "${env_file_rel}" "--flag" "value"
  load_env "$@"
  local rc=$?
  popd >/dev/null || true

  if (( rc != 0 )); then
    fail "load_env returned ${rc}"
  fi

  assert_equal "fixture.local" "${LABZ_DOMAIN}"

  local -a remaining=()
  if [[ ${#LOAD_ENV_ARGS[@]} -gt 0 ]]; then
    remaining=("${LOAD_ENV_ARGS[@]}")
  fi

  assert_equal "2" "${#remaining[@]}"
  assert_equal "--flag" "${remaining[0]}"
  assert_equal "value" "${remaining[1]}"

  set --
}

@test "load_env loads env from --env-file argument" {
  local env_file
  env_file="$(homelab_fixture 'envs/basic.env')"
  set -- "--env-file" "${env_file}" "positional"
  load_env "$@"
  local rc=$?

  if (( rc != 0 )); then
    fail "load_env returned ${rc}"
  fi

  assert_equal "fixture.local" "${LABZ_DOMAIN}"

  local -a remaining=()
  if [[ ${#LOAD_ENV_ARGS[@]} -gt 0 ]]; then
    remaining=("${LOAD_ENV_ARGS[@]}")
  fi

  assert_equal "1" "${#remaining[@]}"
  assert_equal "positional" "${remaining[0]}"

  set --
}
