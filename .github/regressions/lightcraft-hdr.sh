#!/usr/bin/env bash
# HDR PR435: byte-identical Local result must be reused & promoted, undoably.
# Existing workflow pins previous checked HDR head as bootstrap. Select the next
# exact bundled candidate here; shared runner records these pins in evidence.
[[ "$CANDIDATE_SHA" == b017b6c6969f841db507caaca0eec710a9b84eb1 ]] || fail 'unexpected HDR bootstrap pin'
git -C "$repo" fetch "$harness/.github/regressions/lightcraft-hdr-candidate.bundle" 94729f85b8076f22e2848cae6ab5b2de677e4d17
git -C "$repo" checkout --detach 94729f85b8076f22e2848cae6ab5b2de677e4d17
ORIGINAL_HEAD_SHA=b017b6c6969f841db507caaca0eec710a9b84eb1
CANDIDATE_SHA=94729f85b8076f22e2848cae6ab5b2de677e4d17
git -C "$repo" merge-base --is-ancestor "$ORIGINAL_HEAD_SHA" "$CANDIDATE_SHA"


SOURCE_PATHS=(
  crates/engine/src/merge.rs
  crates/engine/src/tests_merge.rs
)
RED_PATCH_FILE='.github/regressions/lightcraft-hdr-red.patch'
HOSTED_QUALIFICATION_PATCH_FILE=''
regression_name='hdr_merge_command_creates_and_imports_a_dng'

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
  grep -Fq 'assertion failed: !s.catalog.photo(id).unwrap().local' "$log" || return 1
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