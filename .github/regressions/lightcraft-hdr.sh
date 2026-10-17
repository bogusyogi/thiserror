#!/usr/bin/env bash
# HDR PR 435. This case stays disabled by the shared runner until its exact red patch is staged.
SOURCE_PATHS=(
  crates/engine/src/merge.rs
  crates/engine/src/tests_merge.rs
)
RED_PATCH_FILE='.github/regressions/lightcraft-hdr-red.patch'
regression_name='hdr_merge_does_not_reuse_a_deleted_result_path_for_a_new_result'

run_preflight() {
  # HDR path regression does not require a GPU adapter.
  printf 'HDR adapter preflight: not applicable\n'
}

verify_test_survives_red() {
  local test_file='crates/engine/src/tests_merge.rs'
  grep -Fq "fn ${regression_name}()" "$test_file" || return 1
  # Red patch must transform merge production behavior only; keep regression code byte-identical.
  [[ "$(git diff --name-only)" == 'crates/engine/src/merge.rs' ]] || return 1
  git diff --quiet -- "$test_file"
}

run_regression_tests() {
  local phase="${1:?phase is required}"
  case "$phase" in
    red)
      cargo test --locked -p lightcraft-engine --lib "$regression_name"
      ;;
    green)
      cargo test --locked -p lightcraft-engine --lib "$regression_name" || return $?
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
  # Original merge restores the deleted row, then its import fails; unwrap must expose that failure.
  grep -Fq 'called `Result::unwrap()` on an `Err` value' "$log" || return 1
  grep -Fq 'could not be imported' "$log" || return 1
  grep -Eq 'panicked at .*tests_merge\.rs:' "$log"
}

verify_no_adapter_skip() {
  local log="${1:?log is required}"
  # HDR test does not use the GPU. Also prove red targeted one test and green ran both commands.
  grep -Fq "$regression_name" "$log" || return 1
  ! grep -Eiq 'no (supported )?adapters?|no devices? found|skipped because.*(adapter|device)' "$log" || return 1
  if grep -Fq 'test result: FAILED.' "$log"; then
    return 0
  fi
  [[ "$(grep -Ec '^test result: ok\. [1-9][0-9]* passed;' "$log")" -eq 2 ]]
}
