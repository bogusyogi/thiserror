#!/usr/bin/env bash
set -euo pipefail
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${CANDIDATE_SHA:?CANDIDATE_SHA is required}"
: "${ORIGINAL_HEAD_SHA:?ORIGINAL_HEAD_SHA is required}"
[[ "$CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$ORIGINAL_HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || exit 2
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
repo="$GITHUB_WORKSPACE/async-trait"
harness="$GITHUB_WORKSPACE/harness"
evidence="$RUNNER_TEMP/async-trait-issue-305-evidence"
test_patch="$harness/.github/regressions/async-trait-305-test-only.patch"
repair_patch="$harness/.github/regressions/async-trait-source-repair.patch"
mkdir -p "$evidence"
[[ -f "$repo/Cargo.toml" && -f "$test_patch" && -f "$repair_patch" ]] || fail 'repository or fixture patches are missing'
cd "$repo"
git cat-file -e "$CANDIDATE_SHA^{commit}" 2>/dev/null || fail 'candidate commit missing'
git cat-file -e "$ORIGINAL_HEAD_SHA^{commit}" 2>/dev/null || fail 'original head missing'
[[ "$(git rev-parse HEAD)" == "$CANDIDATE_SHA" ]] || fail 'checkout HEAD differs from candidate SHA'
git merge-base --is-ancestor "$ORIGINAL_HEAD_SHA" "$CANDIDATE_SHA" || fail 'candidate ancestry check failed'
[[ -z "$(git status --porcelain)" ]] || fail 'candidate checkout is dirty before validation'
printf 'candidate=%s\noriginal_head=%s\n' "$CANDIDATE_SHA" "$ORIGINAL_HEAD_SHA" > "$evidence/commits.txt"
rustc --version | tee "$evidence/rustc-version.txt"
cargo --version > "$evidence/cargo-version.txt"
git status --porcelain=v1 > "$evidence/status-before.txt"
sha256sum src/lifetime.rs > "$evidence/source-hash.candidate.txt"
sha256sum tests/test.rs > "$evidence/test-hash.candidate.txt"

lock_was_present=0
if [[ -e Cargo.lock ]]; then lock_was_present=1; cp Cargo.lock "$RUNNER_TEMP/async-trait-Cargo.lock.before"; fi
repair_reversed=0
restore_all() {
  if [[ "$repair_reversed" == 1 ]]; then git -C "$repo" apply "$repair_patch" || return 1; repair_reversed=0; fi
  if [[ "$lock_was_present" == 0 ]]; then rm -f "$repo/Cargo.lock"; else cp "$RUNNER_TEMP/async-trait-Cargo.lock.before" "$repo/Cargo.lock"; fi
  [[ -z "$(git -C "$repo" status --porcelain)" ]]
}
on_exit() {
  local status=$?
  trap - EXIT
  if ! restore_all; then printf 'ERROR: failed to restore candidate tracked tree\n' >&2; status=1; fi
  exit "$status"
}
trap on_exit EXIT

git diff "$ORIGINAL_HEAD_SHA" "$CANDIDATE_SHA" -- tests/test.rs > "$evidence/test-fixture-from-candidate.diff"
cmp -s "$test_patch" "$evidence/test-fixture-from-candidate.diff" || fail 'candidate test fixture differs from supplied provenance patch'
sha256sum tests/test.rs > "$evidence/test-hash.candidate-verified.txt"
cargo generate-lockfile > "$evidence/lock-generation.log" 2>&1 || { cat "$evidence/lock-generation.log" >&2; fail 'lock generation failed'; }
sha256sum Cargo.lock > "$evidence/Cargo.lock.sha256"
cp Cargo.lock "$RUNNER_TEMP/async-trait-Cargo.lock.generated"

git apply --check --reverse "$repair_patch" || fail 'repair patch cannot be reversed from candidate'
git apply --reverse "$repair_patch"
repair_reversed=1
[[ "$(git diff --name-only | wc -l)" -eq 1 ]] || fail 'red stage changed unexpected files'
git diff --name-only | grep -Fxq src/lifetime.rs || fail 'red stage did not change production source'
git diff --quiet -- tests/test.rs || fail 'red stage changed test fixture'
sha256sum src/lifetime.rs > "$evidence/source-hash.red.txt"
set +e
RUSTFLAGS='-Dwarnings' cargo test --locked --test test --no-run > "$evidence/red.log" 2>&1
red_status=$?
set -e
printf '%s\n' "$red_status" > "$evidence/red-exit.txt"
(( red_status != 0 )) || fail 'expected red compile unexpectedly succeeded'
grep -Fq 'error[E0658]' "$evidence/red.log" || fail 'red compile lacked E0658 diagnostic'
grep -Eiq 'anonymous lifetimes? in impl trait|anonymous lifetime.*impl Trait' "$evidence/red.log" || fail 'red compile lacked anonymous-lifetime-in-impl-Trait diagnostic'
grep -Fq 'tests/test.rs' "$evidence/red.log" || fail 'red diagnostic did not identify issue 305 fixture'
printf 'expected issue 305 E0658 diagnostic reproduced (exit %s)\n' "$red_status" > "$evidence/red-result.txt"

git apply "$repair_patch"
repair_reversed=0
sha256sum src/lifetime.rs > "$evidence/source-hash.restored.txt"
cmp -s "$evidence/source-hash.candidate.txt" "$evidence/source-hash.restored.txt" || fail 'candidate production source not restored'
cmp -s "$evidence/test-hash.candidate.txt" <(sha256sum tests/test.rs) || fail 'candidate test fixture changed during red'
cmp -s "$RUNNER_TEMP/async-trait-Cargo.lock.generated" Cargo.lock || fail 'lock changed during red'
set +e
RUSTFLAGS='-Dwarnings' cargo test --locked > "$evidence/green.log" 2>&1
green_status=$?
set -e
printf '%s\n' "$green_status" > "$evidence/green-exit.txt"
(( green_status == 0 )) || { tail -n 120 "$evidence/green.log" >&2; fail 'candidate green suite failed'; }
grep -Eq '^test result: ok\. [1-9][0-9]* passed;' "$evidence/green.log" || fail 'green run lacks nonempty passing test summary'
! grep -Fq 'test result: FAILED.' "$evidence/green.log" || fail 'green log contains failed summary'
cmp -s "$RUNNER_TEMP/async-trait-Cargo.lock.generated" Cargo.lock || fail 'Cargo.lock changed during green validation'
cmp -s "$evidence/test-hash.candidate.txt" <(sha256sum tests/test.rs) || fail 'candidate test fixture changed during green validation'
printf 'candidate suite passed with committed issue 305 fixture (exit %s)\n' "$green_status" > "$evidence/green-result.txt"

restore_all || fail 'candidate tracked tree restore failed'
trap - EXIT
sha256sum src/lifetime.rs > "$evidence/source-hash.after.txt"
cmp -s "$evidence/source-hash.candidate.txt" "$evidence/source-hash.after.txt" || fail 'source differs after cleanup'
sha256sum tests/test.rs > "$evidence/test-hash.after.txt"
cmp -s "$evidence/test-hash.candidate.txt" "$evidence/test-hash.after.txt" || fail 'test source differs after cleanup'
if [[ "$lock_was_present" == 1 ]]; then cmp -s "$RUNNER_TEMP/async-trait-Cargo.lock.before" Cargo.lock || fail 'original lock differs after cleanup'; fi
git status --porcelain=v1 > "$evidence/status-after.txt"
[[ ! -s "$evidence/status-after.txt" ]] || fail 'candidate tree not clean after cleanup'
printf 'candidate production source and committed test fixture preserved; generated lock removed when absent initially; working tree clean\n' > "$evidence/restore-result.txt"
