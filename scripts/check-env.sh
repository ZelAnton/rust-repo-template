#!/usr/bin/env bash
#
# Checks this machine can build and test this Rust crate before you initialize
# the template (POSIX counterpart of check-env.ps1 — use whichever matches your
# shell; both do the same thing).
#
# Verifies cargo and rustc can each report a usable version. rust-toolchain.toml
# pins the channel and components (rustfmt, clippy), which rustup installs
# automatically on the first build. Exits 0 only after both checks succeed;
# otherwise it reports every failed check and exits 1.
#
# Usage: bash ./scripts/check-env.sh

set -euo pipefail
case "${1:-}" in -h|--help) sed -n '2,13p' "$0"; exit 0 ;; esac

problems=()
echo "==> Checking environment for Rust development"

# Required: cargo (build/test driver) and rustc (the compiler). Resolve the
# executable path so a same-named shell function cannot stand in for the tool.
for tool in cargo rustc; do
  if ! tool_path=$(type -P "$tool"); then
    problems+=("$tool ('$tool' is not on PATH)")
    continue
  fi

  status=0
  if version_output=$("$tool_path" --version 2>/dev/null); then
    :
  else
    status=$?
  fi

  if [ "$status" -ne 0 ]; then
    problems+=("$tool ('$tool --version' exited with code $status)")
  elif [ -z "${version_output//[[:space:]]/}" ]; then
    problems+=("$tool ('$tool --version' returned empty output)")
  elif [[ ! "$version_output" =~ ^[[:space:]]*${tool}[[:space:]]+[^[:space:]]+ ]]; then
    problems+=("$tool ('$tool --version' returned unusable output)")
  else
    echo "    $version_output"
  fi
done

if [ ${#problems[@]} -eq 0 ]; then
  echo
  echo "Environment ready. Next: bash ./scripts/init.sh --project-name ..."
  echo "(rustup installs the pinned stable + rustfmt/clippy on the first cargo build.)"
  exit 0
fi

echo
echo "Environment NOT ready. Problems:"
for p in "${problems[@]}"; do echo "  - $p"; done
echo
echo "Install the Rust toolchain via rustup, then re-run this check:"
echo "  Windows : winget install Rustlang.Rustup ; rustup default stable"
echo "  macOS   : brew install rustup ; rustup-init"
echo "  Linux   : curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
echo "  (any OS) : see https://rustup.rs"
exit 1
