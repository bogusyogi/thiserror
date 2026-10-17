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

# Case config contract. It must define:
#   SOURCE_PATHS=(... tracked source files whose bytes are material to this regression ...)
#   RED_PATCH_FILE=... (unified diff relative to harness; must only change production behavior)
#   run_preflight             (GPU must prove a working Vulkan adapter; HDR may be a no-op)
#   verify_test_survives_red  (prove candidate regression test remains present after patch)
#   run_regression_tests red|green
#   verify_red_failure LOG    (prove expected assertion failed, including exact failure count)
#   verify_no_adapter_skip LOG (GPU must reject adapter/no-device skips; HDR may be a no-op)
source "$config"
for required in SOURCE_PATHS RED_PATCH_FILE; do
  declare -p "$required" >/dev/null 2>&1 || fail "case config must define $required"
done
for required_fn in run_preflight verify_test_survives_red run_regression_tests verify_red_failure verify_no_adapter_skip; do
  declare -F "$required_fn" >/dev/null || fail "case config must implement $required_fn"
done
[[ "${#SOURCE_PATHS[@]}" -gt 0 ]] || fail 'SOURCE_PATHS must list at least one source file'
[[ -f "$harness/$RED_PATCH_FILE" ]] || fail "missing red patch $harness/$RED_PATCH_FILE"

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
hash_sources "$evidence/source-lock-hashes.before.txt"
cp Cargo.lock "$RUNNER_TEMP/lightcraft-${CASE_ID}-Cargo.lock.candidate"
run_preflight > "$evidence/preflight.log" 2>&1 || { tail -n 120 "$evidence/preflight.log" >&2; fail 'preflight failed'; }

patch_applied=0
restore_candidate() {
  if [[ "$patch_applied" == 1 ]]; then
    git -C "$repo" apply --reverse "$harness/$RED_PATCH_FILE" || return 1
    patch_applied=0
    hash_sources "$evidence/source-lock-hashes.restored.txt"
    cmp -s "$evidence/source-lock-hashes.before.txt" "$evidence/source-lock-hashes.restored.txt" || return 1
    [[ -z "$(git -C "$repo" status --porcelain)" ]] || return 1
    printf 'candidate bytes restored and working tree clean\n' > "$evidence/restore-result.txt"
  fi
}
trap 'restore_candidate || printf "ERROR: candidate restoration failed\n" >&2' EXIT

git apply --check "$harness/$RED_PATCH_FILE" || fail 'red patch does not apply cleanly to candidate'
git apply "$harness/$RED_PATCH_FILE"
patch_applied=1
verify_test_survives_red || fail 'candidate regression test did not survive red transformation'
set +e
run_regression_tests red > "$evidence/red.log" 2>&1
red_status=$?
set -e
printf '%s\n' "$red_status" > "$evidence/red-exit.txt"
(( red_status != 0 )) || fail 'red regression unexpectedly passed'
verify_no_adapter_skip "$evidence/red.log" || fail 'red run skipped because adapter/device was unavailable'
verify_red_failure "$evidence/red.log" || { tail -n 120 "$evidence/red.log" >&2; fail 'red log did not prove the expected assertion failure'; }
printf 'expected regression assertion failed (exit %s)\n' "$red_status" > "$evidence/red-result.txt"

restore_candidate || fail 'candidate restoration failed before green run'
trap - EXIT
set +e
run_regression_tests green > "$evidence/green.log" 2>&1
green_status=$?
set -e
printf '%s\n' "$green_status" > "$evidence/green-exit.txt"
(( green_status == 0 )) || { tail -n 120 "$evidence/green.log" >&2; fail 'candidate green validation failed'; }
verify_no_adapter_skip "$evidence/green.log" || fail 'green run skipped because adapter/device was unavailable'
hash_sources "$evidence/source-lock-hashes.after.txt"
cmp -s "$evidence/source-lock-hashes.before.txt" "$evidence/source-lock-hashes.after.txt" || fail 'candidate source or Cargo.lock bytes changed during validation'
cmp -s "$RUNNER_TEMP/lightcraft-${CASE_ID}-Cargo.lock.candidate" Cargo.lock || fail 'Cargo.lock changed during --locked validation'
printf 'candidate regression suite passed (exit 0); candidate source and Cargo.lock hashes unchanged\n' > "$evidence/green-result.txt"
