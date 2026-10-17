#!/usr/bin/env bash
set -euo pipefail

repo="$GITHUB_WORKSPACE/ember"
evidence="$RUNNER_TEMP/brush-1892-evidence"
source_path='crates/ui-egui/src/brush_live.rs'
test_name='incremental_stamping_respects_the_whole_stroke_budget'
mkdir -p "$evidence"
cd "$repo"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail 'CANDIDATE_SHA must be a full commit SHA.'
git cat-file -e "$CANDIDATE_SHA^{commit}" || fail 'candidate commit is missing from full-history checkout'
git cat-file -e "$PR_HEAD_SHA^{commit}" || fail 'PR-head commit is missing from full-history checkout'
[[ -f "$source_path" ]] || fail "missing candidate source: $source_path"

printf 'candidate=%s\npr_head=%s\n' "$CANDIDATE_SHA" "$PR_HEAD_SHA" > "$evidence/commits.txt"
cp "$source_path" "$RUNNER_TEMP/brush-live-fixed.rs"
sha256sum "$RUNNER_TEMP/brush-live-fixed.rs" | tee "$evidence/fixed-source.sha256"
sha256sum Cargo.lock | tee "$evidence/Cargo.lock.sha256.before"

# Reconstruct old stamp behavior by reverting only the helper import and call.
# Keep candidate's emitted field and new regression test so failure exercises the original mismatch.
python3 - "$RUNNER_TEMP/brush-live-fixed.rs" "$RUNNER_TEMP/brush-live-original-stamp.rs" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
old_import = "push_dabs_counted, push_pressures"
new_import = "push_dabs, push_pressures"
old_call = "push_dabs_counted(&mut dabs, &mut self.emitted, self.last, q, r)"
new_call = "push_dabs(&mut dabs, self.last, q, r)"
if source.count(old_import) != 1 or source.count(old_call) != 1:
    raise SystemExit("expected exactly one candidate helper import and call")
Path(sys.argv[2]).write_text(source.replace(old_import, new_import).replace(old_call, new_call), encoding="utf-8")
PY
sha256sum "$RUNNER_TEMP/brush-live-original-stamp.rs" | tee "$evidence/original-stamp-source.sha256"
printf 'Red source changes only helper import/call; emitted field and regression test remain from candidate.\n' > "$evidence/red-source-description.txt"

cp "$RUNNER_TEMP/brush-live-original-stamp.rs" "$source_path"
set +e
cargo test --locked -p lightcraft-ui-egui "brush_live::tests::$test_name" --lib > "$evidence/original-stamp-red.log" 2>&1
red_status=$?
set -e
[[ $red_status -ne 0 ]] || fail 'original stamp behavior unexpectedly passed regression'
grep -Fq "$test_name" "$evidence/original-stamp-red.log" || {
  tail -n 100 "$evidence/original-stamp-red.log" >&2
  fail 'red log did not identify the expected UI regression test'
}
grep -Fq 'test result: FAILED. 0 passed; 1 failed' "$evidence/original-stamp-red.log" || {
  tail -n 100 "$evidence/original-stamp-red.log" >&2
  fail 'red run was not exactly one failing test'
}
grep -Fq 'left: 1999997' "$evidence/original-stamp-red.log" || {
  tail -n 100 "$evidence/original-stamp-red.log" >&2
  fail 'red run did not fail at the emitted-count assertion left value'
}
grep -Fq 'right: 2000000' "$evidence/original-stamp-red.log" || {
  tail -n 100 "$evidence/original-stamp-red.log" >&2
  fail 'red run did not fail at the emitted-count assertion budget value'
}
printf 'Original stamp behavior failed expected emitted-count assertion.\n' > "$evidence/red-result.txt"

# Restore byte-for-byte candidate source before any green checks.
cp "$RUNNER_TEMP/brush-live-fixed.rs" "$source_path"
restored_sha="$(sha256sum "$source_path" | awk '{print $1}')"
expected_sha="$(awk '{print $1}' "$evidence/fixed-source.sha256")"
[[ "$restored_sha" == "$expected_sha" ]] || fail 'candidate source restore hash mismatch'
printf 'restored candidate source sha256=%s\n' "$restored_sha" > "$evidence/restored-source.txt"

run_green() {
  local label="$1"
  shift
  local logfile="$evidence/${label}.log"
  if "$@" > "$logfile" 2>&1; then
    printf '%s: PASS\n' "$label" >> "$evidence/results.txt"
  else
    local status=$?
    printf '%s: FAIL (exit %s)\n' "$label" "$status" >> "$evidence/results.txt"
    tail -n 120 "$logfile" >&2
    return "$status"
  fi
}

run_green pipeline-masks-green cargo test --locked -p lightcraft-pipeline masks::tests --lib || fail 'candidate pipeline mask tests failed'
run_green brush-live-green cargo test --locked -p lightcraft-ui-egui brush_live::tests --lib || fail 'candidate live-brush tests failed'
sha256sum Cargo.lock | tee "$evidence/Cargo.lock.sha256.after"
cmp -s "$evidence/Cargo.lock.sha256.before" "$evidence/Cargo.lock.sha256.after" || fail 'Cargo.lock hash changed during locked validation'
printf 'Cargo.lock unchanged under --locked validation.\n' > "$evidence/lock-result.txt"
