#!/usr/bin/env bash
#
# Initializes this template into a concrete Rust project (POSIX counterpart of
# init.ps1 — use whichever matches your shell; both do the same thing).
#
# Replaces the placeholder tokens (__CrateName__, __Author__, __GitHubOwner__,
# __Description__, __Year__, __Date__) in file contents AND in file/folder names,
# then removes the template-only files (TEMPLATE.md, docs/AGENT-INIT-GUIDE.md)
# and — unless --keep-script — both initializers (init.sh and init.ps1).
#
# Usage:
#   bash ./scripts/init.sh --crate-name my-tool \
#       [--author "Jane Doe"] [--github-owner acme] [--description "A small tool"] \
#       [--year 2026] [--date 2026-01-31] [--keep-script]
#
# --crate-name is required; the rest fall back to sensible defaults so the
# result always builds. Edit LICENSE / Cargo.toml afterwards to refine them.

set -euo pipefail

crate_name=""
author=""
github_owner=""
description=""
year=""
date_str=""
keep_script=0

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --crate-name)   crate_name="${2:-}"; shift 2 ;;
    --author)       author="${2:-}"; shift 2 ;;
    --github-owner) github_owner="${2:-}"; shift 2 ;;
    --description)  description="${2:-}"; shift 2 ;;
    --year)         year="${2:-}"; shift 2 ;;
    --date)         date_str="${2:-}"; shift 2 ;;
    --keep-script)  keep_script=1; shift ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

[ -n "$crate_name" ] || die "--crate-name is required (e.g. --crate-name my-tool)."

# crates.io accepts ASCII alphanumerics plus '-' and '_'; must start with a letter.
case "$crate_name" in
  [A-Za-z]*) : ;;
  *) die "invalid --crate-name '$crate_name'. Start with a letter." ;;
esac
case "$crate_name" in
  *[!A-Za-z0-9_-]*) die "invalid --crate-name '$crate_name'. Use letters, digits, '-' or '_'." ;;
esac

# Defaults (mirror init.ps1).
if [ -z "$author" ]; then
  author="$(git config user.name 2>/dev/null || true)"
  [ -n "$author" ] || author="Your Name"
fi
[ -n "$github_owner" ] || github_owner="your-org"
[ -n "$description" ]  || description="TODO: crate description"
[ -n "$year" ]         || year="$(date +%Y)"
[ -n "$date_str" ]     || date_str="$(date +%F)"

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
self="$script_dir/$(basename "$0")"
sibling_ps1="$script_dir/init.ps1"

# Values written into TOML files (Cargo.toml description/repository) sit inside
# double-quoted strings — escape backslash then quote so a literal " or \ can't
# break the manifest.
toml_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
author_t="$(toml_escape "$author")"
owner_t="$(toml_escape "$github_owner")"
desc_t="$(toml_escape "$description")"
crate_t="$(toml_escape "$crate_name")"
year_t="$(toml_escape "$year")"
date_t="$(toml_escape "$date_str")"

echo "==> Initializing template as '$crate_name'"

# 1) Replace tokens in file contents. Both initializers are skipped: they carry
#    the literal token strings as search keys, so substituting inside them would
#    corrupt the sibling script.
changed=0
while IFS= read -r -d '' file; do
  case "$file" in
    "$self"|"$sibling_ps1") continue ;;
  esac
  case "$file" in
    *.toml) c=$crate_t; a=$author_t; o=$owner_t; d=$desc_t; y=$year_t; dt=$date_t ;;
    *)      c=$crate_name; a=$author; o=$github_owner; d=$description; y=$year; dt=$date_str ;;
  esac
  # Preserve trailing newlines: append a sentinel before capture, strip it after.
  content="$(cat "$file"; printf x)"; content="${content%x}"
  orig="$content"
  content="${content//__CrateName__/$c}"
  content="${content//__Author__/$a}"
  content="${content//__GitHubOwner__/$o}"
  content="${content//__Description__/$d}"
  content="${content//__Year__/$y}"
  content="${content//__Date__/$dt}"
  if [ "$content" != "$orig" ]; then
    printf '%s' "$content" > "$file"
    changed=$((changed + 1))
  fi
done < <(find "$repo_root" -type d \( -name .git -o -name .jj -o -name target \) -prune -o -type f -print0)
echo "    Updated contents in $changed file(s)."

# 2) Rename files and folders whose name contains the crate-name token. -depth
#    processes children before parents so a renamed dir doesn't invalidate paths.
#    (None in the single-crate skeleton; supports `crates/__CrateName__` etc.)
while IFS= read -r -d '' item; do
  case "$item" in
    */.git/*|*/.jj/*|*/target/*) continue ;;
  esac
  dir="$(dirname "$item")"
  base="$(basename "$item")"
  newbase="${base//__CrateName__/$crate_name}"
  if [ "$newbase" != "$base" ]; then
    mv "$item" "$dir/$newbase"
    echo "    Renamed $base -> $newbase"
  fi
done < <(find "$repo_root" -depth -name '*__CrateName__*' -print0)

# 3) Activate Claude Code shared settings if shipped as a .template (no-op for
#    the current active, hook-only settings.json).
if [ -f "$repo_root/.claude/settings.json.template" ]; then
  mv -f "$repo_root/.claude/settings.json.template" "$repo_root/.claude/settings.json"
  echo "    Activated .claude/settings.json"
fi

# 4) Remove template-only files (the agent guide is template meta — pitfalls are
#    logged back to the *template's* copy, so the downstream repo drops it).
rm -f "$repo_root/TEMPLATE.md" "$repo_root/docs/AGENT-INIT-GUIDE.md"
# Drop docs/ if it's now empty.
rmdir "$repo_root/docs" 2>/dev/null || true

echo ""
echo "Done. Next steps:"
echo "  1. cargo build && cargo test"
echo "  2. cargo clippy --all-targets -- -D warnings && cargo fmt --all --check"
echo "  3. Review LICENSE (author/year) and Cargo.toml metadata."
echo "  4. Replace src/main.rs (and tests/integration.rs) with your code,"
echo "     or switch to a library crate (src/lib.rs)."
echo "  5. Fill the Project section of AGENTS.md, then commit."

# 5) Remove both initializers unless asked to keep them.
if [ "$keep_script" -ne 1 ]; then
  rm -f "$sibling_ps1"
  rm -f "$self"
fi
