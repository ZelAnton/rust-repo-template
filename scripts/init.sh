#!/usr/bin/env bash
#
# Initializes this template into a concrete Rust project (POSIX counterpart of
# init.ps1 — use whichever matches your shell; both do the same thing).
#
# Replaces the placeholder tokens (__ProjectName__, __Author__, __AuthorEmail__,
# __GitHubOwner__, __Description__, __Year__) in file contents AND in file/folder names,
# then removes the template-only files (TEMPLATE.md, docs/AGENT-INIT-GUIDE.md)
# and — unless --keep-script — both initializers (init.sh and init.ps1).
#
# Usage:
#   bash ./scripts/init.sh --project-name my-tool \
#       [--author "Jane Doe"] [--author-email you@example.com] \
#       [--github-owner acme] [--description "A small tool"] \
#       [--year 2026] [--keep-script]
#
# --project-name is required; the rest fall back to sensible defaults so the
# result always builds. The crate name (Cargo.toml) is derived from the project
# name as a crates.io-legal slug. Edit LICENSE / Cargo.toml afterwards to refine.

set -euo pipefail

project_name=""
author=""
author_email=""
github_owner=""
description=""
year=""
keep_script=0

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project-name) project_name="${2:-}"; shift 2 ;;
    --author)       author="${2:-}"; shift 2 ;;
    --author-email) author_email="${2:-}"; shift 2 ;;
    --github-owner) github_owner="${2:-}"; shift 2 ;;
    --description)  description="${2:-}"; shift 2 ;;
    --year)         year="${2:-}"; shift 2 ;;
    --keep-script)  keep_script=1; shift ;;
    -h|--help)      sed -n '2,18p' "$0"; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

[ -n "$project_name" ] || die "--project-name is required (e.g. --project-name my-tool)."

# Derive a crates.io-legal crate name from the project name: lowercase, collapse
# runs of non-alphanumerics to '-', trim leading/trailing '-'. The result stays
# within the crates.io-accepted set (ASCII alphanumerics plus '-' and '_').
crate_name="$(printf '%s' "$project_name" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-*//' -e 's/-*$//')"
[ -n "$crate_name" ] || die "invalid --project-name '$project_name'. It must contain at least one ASCII letter or digit so a crate name can be derived (e.g. my-tool)."

# Defaults (mirror init.ps1).
if [ -z "$author" ]; then
  author="$(git config user.name 2>/dev/null || true)"
  [ -n "$author" ] || author="Your Name"
fi
if [ -z "$author_email" ]; then
  author_email="$(git config user.email 2>/dev/null || true)"
  [ -n "$author_email" ] || author_email="you@example.com"
fi
[ -n "$github_owner" ] || github_owner="your-org"
[ -n "$description" ]  || description="TODO: crate description"
[ -n "$year" ]         || year="$(date +%Y)"

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
self="$script_dir/$(basename "$0")"
sibling_ps1="$script_dir/init.ps1"

# Values written into TOML files (Cargo.toml description/repository) sit inside
# double-quoted strings — escape backslash then quote so a literal " or \ can't
# break the manifest.
toml_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
author_t="$(toml_escape "$author")"
author_email_t="$(toml_escape "$author_email")"
owner_t="$(toml_escape "$github_owner")"
desc_t="$(toml_escape "$description")"
crate_t="$(toml_escape "$crate_name")"
year_t="$(toml_escape "$year")"

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
    *.toml) c=$crate_t; a=$author_t; ae=$author_email_t; o=$owner_t; d=$desc_t; y=$year_t ;;
    *)      c=$crate_name; a=$author; ae=$author_email; o=$github_owner; d=$description; y=$year ;;
  esac
  # Preserve trailing newlines: append a sentinel before capture, strip it after.
  content="$(cat "$file"; printf x)"; content="${content%x}"
  orig="$content"
  content="${content//__ProjectName__/$c}"
  content="${content//__Author__/$a}"
  content="${content//__AuthorEmail__/$ae}"
  content="${content//__GitHubOwner__/$o}"
  content="${content//__Description__/$d}"
  content="${content//__Year__/$y}"
  if [ "$content" != "$orig" ]; then
    printf '%s' "$content" > "$file"
    changed=$((changed + 1))
  fi
done < <(find "$repo_root" -type d \( -name .git -o -name .jj -o -name target \) -prune -o -type f -print0)
echo "    Updated contents in $changed file(s)."

# 2) Rename files and folders whose name contains the crate-name token. -depth
#    processes children before parents so a renamed dir doesn't invalidate paths.
#    (None in the single-crate skeleton; supports `crates/__ProjectName__` etc.)
while IFS= read -r -d '' item; do
  case "$item" in
    */.git/*|*/.jj/*|*/target/*) continue ;;
  esac
  dir="$(dirname "$item")"
  base="$(basename "$item")"
  newbase="${base//__ProjectName__/$crate_name}"
  if [ "$newbase" != "$base" ]; then
    mv "$item" "$dir/$newbase"
    echo "    Renamed $base -> $newbase"
  fi
done < <(find "$repo_root" -depth -name '*__ProjectName__*' -print0)

# 3) Activate Claude Code shared settings from the shipped .template (renames
#    .claude/settings.json.template -> .claude/settings.json).
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
