#!/usr/bin/env bash
# HDR PR 435: CLI-process proof of Local-result promotion and stale-match recovery.
# The hosted workflow bootstraps b017, then this config pins the exact new candidate.
[[ "$CANDIDATE_SHA" == b017b6c6969f841db507caaca0eec710a9b84eb1 ]] || fail 'unexpected HDR bootstrap pin'
git -C "$repo" fetch "$harness/.github/regressions/lightcraft-hdr-candidate.bundle" 0250fb4cb6975d7ae01913962556e5a2c0067801
git -C "$repo" checkout --detach 0250fb4cb6975d7ae01913962556e5a2c0067801
ORIGINAL_HEAD_SHA=b017b6c6969f841db507caaca0eec710a9b84eb1
CANDIDATE_SHA=0250fb4cb6975d7ae01913962556e5a2c0067801
git -C "$repo" merge-base --is-ancestor "$ORIGINAL_HEAD_SHA" "$CANDIDATE_SHA"

SOURCE_PATHS=(
  crates/engine/src/merge.rs
  crates/engine/src/tests_merge.rs
  apps/lightcraft-cli/tests/cli.rs
)
RED_PATCH_FILE='.github/regressions/lightcraft-hdr-red.patch'
HOSTED_QUALIFICATION_PATCH_FILE=''
regression_name='hdr_merge_promotes_local_result_and_recovers_from_stale_match'

prepare_hosted_qualification() { :; }
verify_hosted_qualification() { [[ -z "$(git diff --name-only)" ]]; }
clear_hosted_qualification() { :; }

run_preflight() {
  # CLI HDR regression runs through real local processes and needs no GPU adapter.
  printf 'HDR CLI adapter preflight: not applicable\n'
}

verify_test_survives_red() {
  local test_file='apps/lightcraft-cli/tests/cli.rs'
  grep -Fq "fn ${regression_name}()" "$test_file" || return 1
  # Red patch reverses production Local promotion only; preserve both test files byte-for-byte.
  [[ "$(git diff --name-only)" == 'crates/engine/src/merge.rs' ]] || return 1
  git diff --quiet -- crates/engine/src/tests_merge.rs "$test_file"
}

run_regression_tests() {
  local phase="${1:?phase is required}"
  case "$phase" in
    red)
      cargo test --locked -p lightcraft-cli --test cli "$regression_name"
      ;;
    green)
      cargo test --locked -p lightcraft-cli --test cli "$regression_name" || return $?
      cargo test --locked -p lightcraft-engine --lib tests_merge::
      ;;
    *)
      printf 'unknown phase: %s\n' "$phase" >&2
      return 2
      ;;
  esac
}

verify_red_failure() {
  local log="${1:?red log is required}"
  grep -Fq "$regression_name" "$log" || return 1
  grep -Eq '^test result: FAILED\. 0 passed; 1 failed; 0 ignored;' "$log" || return 1
  grep -Fq 'Local result was not promoted' "$log" || return 1
  grep -Eq 'panicked at .*apps/lightcraft-cli/tests/cli\.rs:' "$log"
}

verify_no_adapter_skip() {
  local log="${1:?log is required}"
  grep -Fq "$regression_name" "$log" || return 1
  ! grep -Eiq 'no (supported )?adapters?|no devices? found|skipped because.*(adapter|device)' "$log" || return 1
  if grep -Fq 'test result: FAILED.' "$log"; then
    return 0
  fi
  [[ "$(grep -Ec '^test result: ok\. [1-9][0-9]* passed;' "$log")" -eq 2 ]]
}