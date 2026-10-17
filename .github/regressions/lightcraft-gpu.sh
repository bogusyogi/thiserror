#!/usr/bin/env bash
# GPU PR 1848: shared-device retry exclusion + upload staging OOM cache integrity.
SOURCE_PATHS=(
  crates/gpu/src/budget.rs
  crates/gpu/src/ctx.rs
  crates/gpu/src/lib.rs
  crates/gpu/src/render.rs
  crates/gpu/tests/fallback.rs
)
RED_PATCH_FILE='.github/regressions/lightcraft-gpu-red.patch'
HOSTED_QUALIFICATION_PATCH_FILE='.github/regressions/lightcraft-gpu-software-admission.patch'
budget_test='an_active_retry_excludes_later_renders_until_its_permit_drops'
upload_test='upload_staging_oom_does_not_cache_an_unwritten_shared_source'

prepare_hosted_qualification() {
  export LIGHTCRAFT_ALLOW_SOFTWARE_GPU=1
  printf 'admission=temporary env-gated CPU Vulkan device admission\n' >> "$evidence/qualification-mode.txt"
  grep -m1 -E 'deviceName[[:space:]]*=' "$evidence/vulkaninfo-summary.txt" >> "$evidence/qualification-mode.txt"
}

verify_hosted_qualification() {
  if [[ "${qualification_applied:-0}" == 1 ]]; then
    [[ "${LIGHTCRAFT_ALLOW_SOFTWARE_GPU:-}" == 1 ]] || return 1
    [[ "$(git diff --name-only)" == 'crates/gpu/src/ctx.rs' ]] || return 1
    [[ "$(git diff --numstat)" == $'1\t1\tcrates/gpu/src/ctx.rs' ]] || return 1
    local expected actual
    expected=$'-        if info.device_type == wgpu::DeviceType::Cpu {\n+        if info.device_type == wgpu::DeviceType::Cpu && std::env::var_os("LIGHTCRAFT_ALLOW_SOFTWARE_GPU").is_none() {'
    actual="$(git diff --unified=0 -- crates/gpu/src/ctx.rs | grep -E '^[+-][^+-]' || true)"
    [[ "$actual" == "$expected" ]]
  else
    [[ -z "${LIGHTCRAFT_ALLOW_SOFTWARE_GPU:-}" ]] && [[ -z "$(git diff --name-only)" ]]
  fi
}

clear_hosted_qualification() {
  unset LIGHTCRAFT_ALLOW_SOFTWARE_GPU
}

run_preflight() {
  local summary="$evidence/vulkaninfo-summary.txt"
  command -v vulkaninfo >/dev/null || { printf 'vulkaninfo is unavailable\n' >&2; return 1; }
  vulkaninfo --summary > "$summary" 2>&1 || { cat "$summary" >&2; return 1; }
  grep -Eq 'deviceName[[:space:]]*=[[:space:]]*[^[:space:]]+' "$summary" || {
    cat "$summary" >&2
    printf 'Vulkan reported no usable device name\n' >&2
    return 1
  }
  printf 'Vulkan adapter available: '
  grep -m1 -E 'deviceName[[:space:]]*=' "$summary"
}

verify_test_survives_red() {
  grep -Fq "fn ${budget_test}()" crates/gpu/src/budget.rs || return 1
  grep -Fq "fn ${upload_test}()" crates/gpu/tests/fallback.rs || return 1
  # Keep fault injection and regression tests from the candidate; red changes production only.
  grep -Fq 'Fault::UploadOutOfMemory' crates/gpu/tests/fallback.rs || return 1
  grep -Fq 'the failed upload must be redone before publication' crates/gpu/tests/fallback.rs || return 1
  [[ "$(git diff --name-only)" == $'crates/gpu/src/budget.rs\ncrates/gpu/src/ctx.rs' ]] || return 1
  git diff --quiet -- crates/gpu/tests/fallback.rs
}

run_budget_test() {
  cargo test --locked -p lightcraft-gpu --lib "budget::tests::${budget_test}" -- --exact --nocapture
}
run_upload_test() {
  cargo test --locked -p lightcraft-gpu --test fallback "$upload_test" -- --exact --nocapture --test-threads=1
}

run_regression_tests() {
  local phase="${1:?phase is required}"
  case "$phase" in
    red)
      local budget_status upload_status
      if run_budget_test > "$evidence/red-budget.log" 2>&1; then budget_status=0; else budget_status=$?; fi
      if run_upload_test > "$evidence/red-upload.log" 2>&1; then upload_status=0; else upload_status=$?; fi
      printf 'budget red exit=%s\nupload red exit=%s\n' "$budget_status" "$upload_status"
      cat "$evidence/red-budget.log"
      cat "$evidence/red-upload.log"
      # Shared runner treats any zero exit as a failed red phase; exact failures are checked below.
      if (( budget_status == 0 || upload_status == 0 )); then return 0; fi
      return 1
      ;;
    green)
      run_budget_test || return $?
      run_upload_test || return $?
      cargo test --locked -p lightcraft-gpu --lib budget::tests:: || return $?
      cargo test --locked -p lightcraft-gpu --test fallback -- --nocapture --test-threads=1
      ;;
    *)
      printf 'unknown phase: %s\n' "$phase" >&2
      return 2
      ;;
  esac
}

verify_red_failure() {
  local log="${1:?red log is required}"
  local budget_log="$evidence/red-budget.log"
  local upload_log="$evidence/red-upload.log"
  grep -Fq "$budget_test" "$log" || return 1
  grep -Fq "$upload_test" "$log" || return 1
  grep -Eq '^test result: FAILED\. 0 passed; 1 failed; 0 ignored;' "$budget_log" || return 1

  grep -Fq 'a later render must wait even when its estimate fits' "$budget_log" || return 1
  grep -Fq 'panicked at' "$budget_log" || return 1
  grep -Eq '^test result: FAILED\. 0 passed; 1 failed; 0 ignored;' "$upload_log" || return 1

  if ! grep -Fq 'the failed upload must be redone before publication' "$upload_log" &&
     ! grep -Fq 'retried shared source differs from CPU by' "$upload_log"; then
    return 1
  fi
  grep -Fq 'panicked at' "$upload_log"
}

verify_no_adapter_skip() {
  local log="${1:?log is required}"
  grep -Eiq 'skipped: no GPU adapter|no (supported )?adapters? found|no Vulkan device' "$log" && return 1
  if grep -Fq 'test result: FAILED.' "$log"; then
    return 0
  fi
  [[ "$(grep -Ec '^test result: ok\. [1-9][0-9]* passed;' "$log")" -eq 4 ]]
}
