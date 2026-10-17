#!/usr/bin/env bash
set -euo pipefail

repo="$GITHUB_WORKSPACE/ember"
evidence="$RUNNER_TEMP/jxl-1893-evidence"
source_path='crates/codecs/src/jxl.rs'
test_name='tiny_jxl_tail_does_not_allocate_a_tail_sized_buffer'
mkdir -p "$evidence"
cd "$repo"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail 'CANDIDATE_SHA must be replaced with the reviewed candidate commit SHA.'
git cat-file -e "$CANDIDATE_SHA^{commit}" || fail 'candidate commit is missing from full-history checkout'
git cat-file -e "$PR_HEAD_SHA^{commit}" || fail 'reviewed PR head is missing from checkout history'
git cat-file -e "$BASE_SHA^{commit}" || fail 'reviewed base commit is missing from checkout history'
[[ -f "$source_path" ]] || fail "missing candidate source: $source_path"

printf 'candidate=%s\npr_head=%s\nbase=%s\n' "$CANDIDATE_SHA" "$PR_HEAD_SHA" "$BASE_SHA" > "$evidence/commits.txt"
cp "$source_path" "$RUNNER_TEMP/jxl-1893-fixed-jxl.rs"
sha256sum "$RUNNER_TEMP/jxl-1893-fixed-jxl.rs" | tee "$evidence/fixed-source.sha256"

# Resolve metadata against the candidate's existing lock. Cargo adds only the
# new workspace dev-dependency edge; do not regenerate unrelated locked versions.
cp Cargo.lock "$evidence/Cargo.lock.before"
cargo metadata --format-version 1 > "$evidence/cargo-metadata.json" 2> "$evidence/cargo-metadata.stderr.log" || {
  tail -n 80 "$evidence/cargo-metadata.stderr.log" >&2
  exit 1
}
cp Cargo.lock "$evidence/generated-Cargo.lock"
git diff --binary "$CANDIDATE_SHA" -- Cargo.lock > "$evidence/Cargo.lock.patch"
python3 - "$evidence/Cargo.lock.before" Cargo.lock <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as stream:
    before = tomllib.load(stream)
with open(sys.argv[2], "rb") as stream:
    after = tomllib.load(stream)

old_packages = before["package"]
new_packages = after["package"]
if len(old_packages) != len(new_packages):
    raise SystemExit("Cargo metadata added or removed lock packages; expected only lightcraft-codecs -> dhat")

old_codecs = [p for p in old_packages if p["name"] == "lightcraft-codecs"]
new_codecs = [p for p in new_packages if p["name"] == "lightcraft-codecs"]
if len(old_codecs) != 1 or len(new_codecs) != 1:
    raise SystemExit("expected one lightcraft-codecs package in lockfile")

old_dependencies = old_codecs[0]["dependencies"]
new_dependencies = new_codecs[0]["dependencies"]
if "dhat" in old_dependencies or new_dependencies.count("dhat") != 1:
    raise SystemExit("expected metadata to add exactly one lightcraft-codecs dhat dependency")
if sorted(new_dependencies) != sorted(old_dependencies + ["dhat"]):
    raise SystemExit("lightcraft-codecs lock dependencies changed beyond dhat")

for old_package in old_packages:
    matches = [p for p in new_packages if (p["name"], p["version"], p.get("source")) == (old_package["name"], old_package["version"], old_package.get("source"))]
    if len(matches) != 1:
        raise SystemExit(f"locked package changed or disappeared: {old_package['name']} {old_package['version']}")
    new_package = matches[0]
    if old_package["name"] == "lightcraft-codecs":
        old_copy = dict(old_package)
        new_copy = dict(new_package)
        old_copy["dependencies"] = sorted(old_copy["dependencies"])
        new_copy["dependencies"] = sorted(new_copy["dependencies"])
        new_copy["dependencies"].remove("dhat")
        if old_copy != new_copy:
            raise SystemExit("lightcraft-codecs lock metadata changed beyond dhat")
    elif old_package != new_package:
        raise SystemExit(f"locked package metadata changed: {old_package['name']} {old_package['version']}")
PY
printf 'Cargo.lock diff verified: only lightcraft-codecs -> dhat dependency edge added.\n' > "$evidence/lock-diff-check.txt"

run_test() {
  local label="$1"
  local test_target="$2"
  local logfile="$evidence/${label}.log"
  local -a args=(cargo test -p lightcraft-codecs)
  if [[ "$test_target" == 'focused' ]]; then
    args+=(--test jxl_tail_heap -- --nocapture --test-threads=1)
  fi
  if "${args[@]}" > "$logfile" 2>&1; then
    printf '%s: PASS\n' "$label" >> "$evidence/results.txt"
  else
    local status=$?
    printf '%s: FAIL (exit %s)\n' "$label" "$status" >> "$evidence/results.txt"
    return "$status"
  fi
}

# Reproduce the reviewer's exact peak-heap failure on the original PR source.
git show "$PR_HEAD_SHA:$source_path" > "$source_path"
set +e
cargo test -p lightcraft-codecs --test jxl_tail_heap -- --nocapture --test-threads=1 > "$evidence/pr-head-red.log" 2>&1
red_status=$?
set -e
[[ $red_status -ne 0 ]] || fail 'PR head unexpectedly passed heap-budget regression'
grep -Fq "test $test_name" "$evidence/pr-head-red.log" || {
  tail -n 100 "$evidence/pr-head-red.log" >&2
  fail 'PR-head log did not name the expected regression test'
}
grep -Fq 'test result: FAILED. 0 passed; 1 failed' "$evidence/pr-head-red.log" || {
  tail -n 100 "$evidence/pr-head-red.log" >&2
  fail 'PR-head failure summary was not the expected single-test failure'
}
grep -Eq 'tiny image used [0-9]+ heap bytes' "$evidence/pr-head-red.log" || {
  tail -n 100 "$evidence/pr-head-red.log" >&2
  fail 'PR-head regression did not fail on the heap budget assertion'
}
peak="$(sed -n 's/.*peak heap bytes: \([0-9][0-9]*\).*/\1/p' "$evidence/pr-head-red.log" | tail -n 1)"
[[ -n "$peak" ]] || fail 'could not extract measured peak heap bytes'
(( peak >= 131072 )) || fail "expected measured PR-head peak to exceed 128 KiB; got $peak"
printf 'PR-head red confirmed; peak heap bytes=%s\n' "$peak" >> "$evidence/results.txt"

# Same original test against the reviewed pre-fix base must pass.
git show "$BASE_SHA:$source_path" > "$source_path"
run_test base-green focused || {
  tail -n 100 "$evidence/base-green.log" >&2
  fail 'base revision did not pass the heap regression test'
}

# Restore exact candidate bytes, prove restoration, then require both focused and crate-wide green runs.
cp "$RUNNER_TEMP/jxl-1893-fixed-jxl.rs" "$source_path"
restored_sha="$(sha256sum "$source_path" | awk '{print $1}')"
expected_sha="$(awk '{print $1}' "$evidence/fixed-source.sha256")"
[[ "$restored_sha" == "$expected_sha" ]] || fail 'fixed candidate source restoration hash mismatch'
printf 'fixed candidate source restored before green tests: %s\n' "$restored_sha" > "$evidence/restored-source.txt"
run_test candidate-focused-green focused || {
  tail -n 100 "$evidence/candidate-focused-green.log" >&2
  fail 'restored candidate failed focused heap regression test'
}
run_test candidate-codecs-green all || {
  tail -n 100 "$evidence/candidate-codecs-green.log" >&2
  fail 'restored candidate failed lightcraft-codecs tests'
}

