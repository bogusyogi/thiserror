#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${CASE_ID:?CASE_ID must name a configured regression}"
: "${CANDIDATE_SHA:?CANDIDATE_SHA must be supplied by the workflow}"
: "${ORIGINAL_HEAD_SHA:?ORIGINAL_HEAD_SHA must be supplied by the workflow}"
[[ "$CASE_ID" == gpu || "$CASE_ID" == hdr ]] || fail 'CASE_ID must be gpu or hdr'
[[ "$CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail 'CANDIDATE_SHA must be a full 40-character commit SHA'
[[ "$ORIGINAL_HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || fail 'ORIGINAL_HEAD_SHA must be a full 40-character commit SHA'

repo="$GITHUB_WORKSPACE/ember"
harness="$GITHUB_WORKSPACE/harness"
evidence="$RUNNER_TEMP/lightcraft-${CASE_ID}-evidence"
config="$harness/.github/regressions/lightcraft-${CASE_ID}.sh"
mkdir -p "$evidence"
[[ -f "$config" ]] || fail "missing case config $config; regression details must be supplied before integration"

# Case config defines source paths, patches and proof hooks for this regression.
source "$config"
for required in SOURCE_PATHS RED_PATCH_FILE HOSTED_QUALIFICATION_PATCH_FILE; do
  declare -p "$required" >/dev/null 2>&1 || fail "case config must define $required"
done
for required_fn in run_preflight prepare_hosted_qualification verify_hosted_qualification clear_hosted_qualification verify_test_survives_red run_regression_tests verify_red_failure verify_no_adapter_skip; do
  declare -F "$required_fn" >/dev/null || fail "case config must implement $required_fn"
done
[[ "${#SOURCE_PATHS[@]}" -gt 0 ]] || fail 'SOURCE_PATHS must list at least one source file'
[[ -f "$harness/$RED_PATCH_FILE" ]] || fail "missing red patch $harness/$RED_PATCH_FILE"
if [[ -n "$HOSTED_QUALIFICATION_PATCH_FILE" ]]; then
  [[ -f "$harness/$HOSTED_QUALIFICATION_PATCH_FILE" ]] || fail "missing hosted qualification patch $harness/$HOSTED_QUALIFICATION_PATCH_FILE"
fi

cd "$repo"
git cat-file -e "$CANDIDATE_SHA^{commit}" 2>/dev/null || fail 'candidate commit is missing from full-history checkout'
git cat-file -e "$ORIGINAL_HEAD_SHA^{commit}" 2>/dev/null || fail 'original head commit is missing from full-history checkout'
[[ "$(git rev-parse HEAD)" == "$CANDIDATE_SHA" ]] || fail 'candidate checkout HEAD differs from CANDIDATE_SHA'
[[ -z "$(git status --porcelain)" ]] || fail 'candidate checkout is not clean before validation'

printf 'case=%s\ncandidate=%s\noriginal_head=%s\n' "$CASE_ID" "$CANDIDATE_SHA" "$ORIGINAL_HEAD_SHA" > "$evidence/commits.txt"
rustc --version > "$evidence/rustc-version.txt"
cargo --version > "$evidence/cargo-version.txt"
git status --porcelain=v1 > "$evidence/status-before.txt"

hash_sources() {
  local out="$1"
  : > "$out"
  for path in "${SOURCE_PATHS[@]}"; do
    [[ -f "$path" ]] || fail "configured source path missing: $path"
    sha256sum "$path" >> "$out"
  done
  sha256sum Cargo.lock >> "$out"
}
hash_sources "$evidence/source-lock-hashes.candidate.txt"
cp Cargo.lock "$RUNNER_TEMP/lightcraft-${CASE_ID}-Cargo.lock.candidate"

red_applied=0
qualification_applied=0
restore_red_transformation() {
  if [[ "$red_applied" == 1 ]]; then
    git -C "$repo" apply --reverse "$harness/$RED_PATCH_FILE" || return 1
    red_applied=0
    verify_hosted_qualification || return 1
    hash_sources "$evidence/source-lock-hashes.red-restored.txt"
    cmp -s "$evidence/source-lock-hashes.qualification-active.txt" "$evidence/source-lock-hashes.red-restored.txt" || return 1
    printf 'red production transformation reversed; hosted qualification remains active\n' > "$evidence/red-restore-result.txt"
  fi
}
restore_all_mutations() {
  restore_red_transformation || return 1
  if [[ "$qualification_applied" == 1 ]]; then
    git -C "$repo" apply --reverse "$harness/$HOSTED_QUALIFICATION_PATCH_FILE" || return 1
    qualification_applied=0
  fi
  clear_hosted_qualification || return 1
  verify_hosted_qualification || return 1
  hash_sources "$evidence/source-lock-hashes.candidate-restored.txt"
  cmp -s "$evidence/source-lock-hashes.candidate.txt" "$evidence/source-lock-hashes.candidate-restored.txt" || return 1
  [[ -z "$(git -C "$repo" status --porcelain)" ]] || return 1
  printf 'candidate source and lock bytes restored; working tree clean\n' > "$evidence/candidate-restore-result.txt"
}
on_exit() {
  local status=$?
  trap - EXIT
  if ! restore_all_mutations; then
    printf 'ERROR: candidate restoration failed\n' >&2
    status=1
  fi
  exit "$status"
}
trap on_exit EXIT

run_preflight > "$evidence/preflight.log" 2>&1 || { tail -n 120 "$evidence/preflight.log" >&2; fail 'preflight failed'; }
if [[ -n "$HOSTED_QUALIFICATION_PATCH_FILE" ]]; then
  git apply --check "$harness/$HOSTED_QUALIFICATION_PATCH_FILE" || fail 'hosted qualification patch does not apply cleanly to candidate'
  git apply "$harness/$HOSTED_QUALIFICATION_PATCH_FILE"
  qualification_applied=1
  sha256sum "$harness/$HOSTED_QUALIFICATION_PATCH_FILE" > "$evidence/qualification-patch.sha256"
  git diff --unified=0 -- crates/gpu/src/ctx.rs > "$evidence/qualification.diff"
  printf 'mode=hosted-software-adapter-qualification\npatch=%s\nred_and_green_use_qualified_source=true\n' "$HOSTED_QUALIFICATION_PATCH_FILE" > "$evidence/qualification-mode.txt"
else
  printf 'mode=none\n' > "$evidence/qualification-mode.txt"
fi
prepare_hosted_qualification || fail 'hosted qualification setup failed'
verify_hosted_qualification || fail 'hosted qualification diff is not the exact configured mutation'
hash_sources "$evidence/source-lock-hashes.qualification-active.txt"

[[ -z "$(git -C "$repo" diff --check)" ]] || fail 'candidate qualification diff has whitespace errors'
git apply --check "$harness/$RED_PATCH_FILE" || fail 'red patch does not apply cleanly to qualified candidate'
git apply "$harness/$RED_PATCH_FILE"
red_applied=1
verify_test_survives_red || fail 'candidate regression test or fault injection did not survive red transformation'
set +e
run_regression_tests red > "$evidence/red.log" 2>&1
red_status=$?
set -e
printf '%s\n' "$red_status" > "$evidence/red-exit.txt"
(( red_status != 0 )) || fail 'red regressions unexpectedly passed'
verify_no_adapter_skip "$evidence/red.log" || fail 'red run skipped because adapter/device was unavailable'
verify_red_failure "$evidence/red.log" || { tail -n 120 "$evidence/red.log" >&2; fail 'red log did not prove the expected assertion failures'; }
printf 'expected regression assertions failed (exit %s) under hosted qualification\n' "$red_status" > "$evidence/red-result.txt"

restore_red_transformation || fail 'red transformation restore failed before green run'
set +e
run_regression_tests green > "$evidence/green.log" 2>&1
green_status=$?
set -e
printf '%s\n' "$green_status" > "$evidence/green-exit.txt"
(( green_status == 0 )) || { tail -n 120 "$evidence/green.log" >&2; fail 'qualified candidate green validation failed'; }
verify_no_adapter_skip "$evidence/green.log" || fail 'green run skipped because adapter/device was unavailable'
printf 'candidate regressions passed under hosted qualification; temporary admission mutation will now be reverted\n' > "$evidence/green-result.txt"

restore_all_mutations || fail 'hosted qualification restore failed after green run'
trap - EXIT
hash_sources "$evidence/source-lock-hashes.after.txt"
cmp -s "$evidence/source-lock-hashes.candidate.txt" "$evidence/source-lock-hashes.after.txt" || fail 'candidate source or Cargo.lock bytes differ after validation'
cmp -s "$RUNNER_TEMP/lightcraft-${CASE_ID}-Cargo.lock.candidate" Cargo.lock || fail 'Cargo.lock changed during --locked validation'
git status --porcelain=v1 > "$evidence/status-after.txt"
printf 'source and Cargo.lock hashes equal original candidate bytes after all validation stages\n' > "$evidence/lock-result.txt"
