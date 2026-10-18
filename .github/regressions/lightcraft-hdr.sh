#!/usr/bin/env bash
# HDR PR 435: stale matching stored sources must trigger a fresh fallback import.
SOURCE_PATHS=(
  crates/engine/src/merge.rs
  crates/engine/src/tests_merge.rs
)
RED_PATCH_FILE='.github/regressions/lightcraft-hdr-red.patch'
HOSTED_QUALIFICATION_PATCH_FILE=''
regression_name='hdr_merge_fresh_imports_when_matching_stored_hash_has_stale_source'

prepare_hosted_qualification() { :; }
verify_hosted_qualification() { [[ -z "$(git diff --name-only)" ]]; }
clear_hosted_qualification() { :; }

run_preflight() {
  # HDR path regression does not require a GPU adapter.
  printf 'HDR adapter preflight: not applicable\n'
}

verify_test_survives_red() {
  local test_file='crates/engine/src/tests_merge.rs'
  grep -Fq "fn ${regression_name}()" "$test_file" || return 1
  # Red transformation touches production behavior only; keep test bytes identical.
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
  grep -Fq 'existing merge result' "$log" || return 1
  grep -Fq 'missing or changed' "$log" || return 1
  grep -Eq 'panicked at .*tests_merge\.rs:' "$log"
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