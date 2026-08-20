#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
check_script="$script_dir/../../scripts/check-env.sh"
bash_path=$(command -v bash)

assert_contains() {
  local text=$1 expected=$2 scenario=$3
  if [[ "$text" != *"$expected"* ]]; then
    printf '%s\n' "$scenario: expected output to contain '$expected'. Actual output:" "$text" >&2
    return 1
  fi
}

write_fake_tool() {
  local bin=$1 tool=$2 behavior=$3 path="$1/$2"
  case "$behavior" in
    success) printf '#!/bin/sh\nprintf "%%s\\n" "%s 1.2.3-fake"\n' "$tool" >"$path" ;;
    failure) printf '#!/bin/sh\nexit 23\n' >"$path" ;;
    empty) printf '#!/bin/sh\nexit 0\n' >"$path" ;;
    unusable) printf '#!/bin/sh\nprintf "%%s\\n" "not-a-version"\n' >"$path" ;;
  esac
  chmod +x "$path"
}

run_scenario() {
  local name=$1 cargo_behavior=$2 rustc_behavior=$3 expected_exit=$4
  shift 4
  local root bin output status expected
  root=$(mktemp -d)
  bin="$root/bin"
  mkdir "$bin"
  if [[ "$cargo_behavior" != missing ]]; then write_fake_tool "$bin" cargo "$cargo_behavior"; fi
  if [[ "$rustc_behavior" != missing ]]; then write_fake_tool "$bin" rustc "$rustc_behavior"; fi

  status=0
  if output=$(PATH="$bin" "$bash_path" "$check_script" 2>&1); then
    :
  else
    status=$?
  fi
  rm -rf -- "$root"

  if [[ "$status" -ne "$expected_exit" ]]; then
    printf '%s\n' "$name: expected exit $expected_exit, got $status. Output:" "$output" >&2
    return 1
  fi
  for expected in "$@"; do assert_contains "$output" "$expected" "$name"; done
  if [[ "$expected_exit" -ne 0 && "$output" == *'Environment ready.'* ]]; then
    printf '%s\n' "$name: failure output must not declare the environment ready." >&2
    return 1
  fi
}

run_scenario success success success 0 \
  'cargo 1.2.3-fake' 'rustc 1.2.3-fake' 'Environment ready.'
run_scenario cargo-missing missing success 1 \
  "cargo ('cargo' is not on PATH)" 'rustc 1.2.3-fake' 'Environment NOT ready.'
run_scenario rustc-missing success missing 1 \
  "rustc ('rustc' is not on PATH)" 'cargo 1.2.3-fake' 'Environment NOT ready.'
run_scenario cargo-failure failure success 1 \
  "cargo ('cargo --version' exited with code 23)" 'rustc 1.2.3-fake'
run_scenario rustc-failure success failure 1 \
  "rustc ('rustc --version' exited with code 23)" 'cargo 1.2.3-fake'
run_scenario cargo-empty empty success 1 \
  "cargo ('cargo --version' returned empty output)" 'rustc 1.2.3-fake'
run_scenario rustc-empty success empty 1 \
  "rustc ('rustc --version' returned empty output)" 'cargo 1.2.3-fake'
run_scenario cargo-unusable unusable success 1 \
  "cargo ('cargo --version' returned unusable output)" 'rustc 1.2.3-fake'
run_scenario rustc-unusable success unusable 1 \
  "rustc ('rustc --version' returned unusable output)" 'cargo 1.2.3-fake'
run_scenario both-fail failure failure 1 \
  "cargo ('cargo --version' exited with code 23)" \
  "rustc ('rustc --version' exited with code 23)"

printf '%s\n' 'POSIX check-env scenarios passed.'
