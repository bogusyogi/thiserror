#!/usr/bin/env bash
# PR 1848: recoverable OOM while creating the kernel parameter buffer.
SOURCE_PATHS=(
  crates/gpu/src/budget.rs
  crates/gpu/src/ctx.rs
  crates/gpu/src/lib.rs
  crates/gpu/src/render.rs
  crates/gpu/tests/fallback.rs
)
RED_PATCH_FILE='.github/regressions/lightcraft-gpu-red.patch'
HOSTED_QUALIFICATION_PATCH_FILE='.github/regressions/lightcraft-gpu-software-admission.patch'
parameter_test='parameter_allocation_oom_is_recoverable_before_binding'

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
clear_hosted_qualification() { unset LIGHTCRAFT_ALLOW_SOFTWARE_GPU; }
run_preflight() {
  local summary="$evidence/vulkaninfo-summary.txt"
  command -v vulkaninfo >/dev/null || { printf 'vulkaninfo unavailable\n' >&2; return 1; }
  vulkaninfo --summary > "$summary" 2>&1 || { cat "$summary" >&2; return 1; }
  grep -Eq 'deviceName[[:space:]]*=[[:space:]]*[^[:space:]]+' "$summary" || { cat "$summary" >&2; return 1; }
  grep -m1 -E 'deviceName[[:space:]]*=' "$summary"
}
verify_test_survives_red() {
  grep -Fq "fn ${parameter_test}()" crates/gpu/src/ctx.rs || return 1
  grep -Fq 'SimulatedParameterOom::new(staging)' crates/gpu/src/ctx.rs || return 1
  grep -Fq 'parameter allocation must report OOM' crates/gpu/src/ctx.rs || return 1
  [[ "$(git diff --name-only)" == 'crates/gpu/src/ctx.rs' ]]
}
run_parameter_test() {
  cargo test --locked -p lightcraft-gpu --lib "ctx::tests::${parameter_test}" -- --exact --nocapture
}
run_regression_tests() {
  case "${1:?phase required}" in
    red) run_parameter_test ;;
    green)
      run_parameter_test || return $?
      cargo test --locked -p lightcraft-gpu --test fallback -- --nocapture --test-threads=1 || return $?
      cargo test --locked -p lightcraft-gpu --lib budget::tests::
      ;;
    *) printf 'unknown phase\n' >&2; return 2 ;;
  esac
}
verify_red_failure() {
  local log="${1:?log required}"
  grep -Eiq '(^error(\[[A-Z0-9]+\])?:|could not compile|failed to compile|running 0 tests|0 passed; 0 failed)' "$log" && return 1
  grep -Fq "${parameter_test}" "$log" || return 1
  grep -Eq '^test result: FAILED\. 0 passed; 1 failed; 0 ignored;' "$log" || return 1
  grep -Fq 'parameter allocation must report OOM' "$log"
}
verify_no_adapter_skip() {
  local log="${1:?log required}"
  grep -Eiq 'skipped: no GPU adapter|no (supported )?adapters? found|no Vulkan device|no GPU adapter' "$log" && return 1
  if grep -Fq 'test result: FAILED.' "$log"; then return 0; fi
  ! grep -Eiq 'running 0 tests|0 passed; 0 failed' "$log" || return 1
  [[ "$(grep -Ec '^test result: ok\. [1-9][0-9]* passed;' "$log")" -ge 3 ]]
}