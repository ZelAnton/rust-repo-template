#!/usr/bin/env bash
#
# Initializes this template into a concrete Rust project (POSIX counterpart of
# init.ps1 — use whichever matches your shell; both do the same thing).
#
# Replaces the placeholder tokens (__ProjectName__, __Author__, __AuthorEmail__,
# __GitHubOwner__, __Description__, __Year__) in file contents AND in file/folder names,
# then removes the template-only files (TEMPLATE.md, docs/AGENT-INIT-GUIDE.md,
# the initializer security regression harness and its CI step) and — unless
# --keep-script — both initializers (init.sh and init.ps1).
#
# Usage:
#   bash ./scripts/init.sh --project-name my-tool \
#       [--author "Jane Doe"] [--author-email you@example.com] \
#       [--github-owner acme] [--description "A small tool"] \
#       [--year 2026] [--keep-script]
#
# --project-name is required; the rest fall back to sensible defaults so the
# result always builds. A crates.io-legal slug is derived from the project name
# (lowercased, non-alphanumerics -> '-', e.g. "Acme.Widgets" -> "acme-widgets")
# and that slug is substituted for every __ProjectName__ token: the crate name,
# the `repository` URL, and any token-named files/folders (never the original
# casing). The slug must start with a letter (cargo rejects a leading digit; init
# errors if it does not). Name your GitHub repo with the slug, or edit Cargo.toml
# / LICENSE to refine.

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
    -h|--help)      sed -n '2,24p' "$0"; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

[ -n "$project_name" ] || die "--project-name is required (e.g. --project-name my-tool)."

# Derive a crates.io-legal crate name from the project name: lowercase, collapse
# runs of non-alphanumerics to '-', trim leading/trailing '-'. The result stays
# within the crates.io-accepted set (ASCII alphanumerics plus '-' and '_').
crate_name="$(printf '%s' "$project_name" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-*//' -e 's/-*$//')"
[ -n "$crate_name" ] || die "invalid --project-name '$project_name'. It must contain at least one ASCII letter or digit so a crate name can be derived (e.g. my-tool)."
# cargo rejects a crate name that starts with a digit ("the name cannot start
# with a digit"). The slug derivation above can't fix that, so fail clearly here
# rather than emitting a Cargo.toml that won't build.
case "$crate_name" in
  [a-z]*) : ;;
  *) die "invalid --project-name '$project_name' -> derived crate name '$crate_name' starts with a non-letter; cargo requires a crate name that starts with a letter. Pick a project name whose first alphanumeric is a letter (e.g. my-tool)." ;;
esac

# Defaults (mirror init.ps1).
read_git_config_value() {
  # NUL termination lets `read` preserve embedded and trailing line breaks;
  # ordinary command substitution would strip trailing LF bytes before validation.
  git_config_value=""
  IFS= read -r -d '' git_config_value < <(git config --null --get "$1" 2>/dev/null) || return 1
}

if [ -z "$author" ]; then
  if read_git_config_value user.name; then author="$git_config_value"; fi
  [ -n "$author" ] || author="Your Name"
fi
if [ -z "$author_email" ]; then
  if read_git_config_value user.email; then author_email="$git_config_value"; fi
  [ -n "$author_email" ] || author_email="you@example.com"
fi
[ -n "$github_owner" ] || github_owner="your-org"
[ -n "$description" ]  || description="TODO: crate description"
[ -n "$year" ]         || year="$(date +%Y)"

validate_release_identity() {
  case "$2" in
    *$'\r'*|*$'\n'*)
      die "invalid $1: release identity values must be a single line; CR and LF characters are not supported."
      ;;
  esac

  # Ask Git's ident formatter to round-trip each value against a fixed safe
  # counterpart. Git strips more boundary punctuation than its config store;
  # probing the formatter keeps this contract complete without duplicating its
  # evolving internal blacklist here.
  if [ "$1" = "--author" ]; then
    probe_name="$2"
    probe_email="probe@example.invalid"
  else
    probe_name="Release Identity Probe"
    probe_email="$2"
  fi
  expected_ident="$probe_name <$probe_email> 0 +0000"
  rendered_ident="$(
    GIT_AUTHOR_NAME="$probe_name" \
    GIT_AUTHOR_EMAIL="$probe_email" \
    GIT_AUTHOR_DATE='@0 +0000' \
      git var GIT_AUTHOR_IDENT 2>/dev/null
  )" || die "invalid $1: Git could not validate the release identity value."
  [ "$rendered_ident" = "$expected_ident" ] ||
    die "invalid $1: release identity value is not preserved exactly when Git formats a commit identity; Git would strip or alter characters."
}

# Command substitution strips trailing newlines after decoding, and Git
# identities are single-line values. Reject line breaks before touching the
# template so both initializer paths have the same lossless contract.
validate_release_identity "--author" "$author"
validate_release_identity "--author-email" "$author_email"

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
self="$script_dir/$(basename "$0")"
sibling_ps1="$script_dir/init.ps1"
release_workflow="$repo_root/.github/workflows/release.yml"
ci_workflow="$repo_root/.github/workflows/ci.yml"
security_tests="$repo_root/tests/init-security"

# In release.yml the author placeholders are data, not Bash source. Base64 keeps
# every shell/YAML metacharacter out of the serialized workflow while preserving
# the exact UTF-8 value for the quoted git-config calls at release time.
base64_utf8() { printf '%s' "$1" | base64 | tr -d '\r\n'; }
author_release="$(base64_utf8 "$author")"
author_email_release="$(base64_utf8 "$author_email")"

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

entry_exists() { [ -e "$1" ] || [ -L "$1" ]; }

# Build every mutation plan before the first write. The arrays deliberately use
# Bash 3-compatible indexed arrays so the initializer retains macOS support.
content_files=()
content_count=0
while IFS= read -r -d '' file; do
  case "$file" in
    "$self"|"$sibling_ps1"|"$security_tests"/*) continue ;;
  esac
  content_files[content_count]="$file"
  content_count=$((content_count + 1))
done < <(
  find "$repo_root" \
    \( -type d \( -name .git -o -name .jj -o -name target \) -o -path "$security_tests" \) -prune \
    -o -type f -print0
)

# Keep the content and rename plans deterministic without relying on GNU
# `sort -z`, which is absent from the default macOS toolchain.
for ((i = 0; i < content_count; i++)); do
  for ((j = i + 1; j < content_count; j++)); do
    if [[ "${content_files[j]}" < "${content_files[i]}" ]]; then
      swap="${content_files[i]}"
      content_files[i]="${content_files[j]}"
      content_files[j]="$swap"
    fi
  done
done

rename_sources=()
rename_destinations=()
rename_source_relatives=()
rename_destination_relatives=()
rename_depths=()
rename_count=0
while IFS= read -r -d '' item; do
  dir="${item%/*}"
  base="${item##*/}"
  newbase="${base//__ProjectName__/$crate_name}"
  source_relative="${item#"$repo_root"/}"
  destination="$dir/$newbase"
  destination_relative="${destination#"$repo_root"/}"
  depth=0
  depth_tail="$source_relative"
  while [[ "$depth_tail" == */* ]]; do
    depth_tail="${depth_tail#*/}"
    depth=$((depth + 1))
  done
  rename_sources[rename_count]="$item"
  rename_destinations[rename_count]="$destination"
  rename_source_relatives[rename_count]="$source_relative"
  rename_destination_relatives[rename_count]="$destination_relative"
  rename_depths[rename_count]="$depth"
  rename_count=$((rename_count + 1))
done < <(
  find "$repo_root" \
    \( -type d \( -name .git -o -name .jj -o -name target \) -o -path "$security_tests" \) -prune \
    -o -name '*__ProjectName__*' -print0
)

# Deepest sources run first; equal-depth paths use lexical order. This mirrors
# init.ps1 and prevents a parent rename from invalidating an unprocessed child.
for ((i = 1; i < rename_count; i++)); do
  key_source="${rename_sources[i]}"
  key_destination="${rename_destinations[i]}"
  key_source_relative="${rename_source_relatives[i]}"
  key_destination_relative="${rename_destination_relatives[i]}"
  key_depth="${rename_depths[i]}"
  j=$((i - 1))
  while ((j >= 0)); do
    precedes=0
    if ((key_depth > rename_depths[j])); then
      precedes=1
    elif ((key_depth == rename_depths[j])) && [[ "$key_source_relative" < "${rename_source_relatives[j]}" ]]; then
      precedes=1
    fi
    ((precedes == 1)) || break
    rename_sources[j + 1]="${rename_sources[j]}"
    rename_destinations[j + 1]="${rename_destinations[j]}"
    rename_source_relatives[j + 1]="${rename_source_relatives[j]}"
    rename_destination_relatives[j + 1]="${rename_destination_relatives[j]}"
    rename_depths[j + 1]="${rename_depths[j]}"
    j=$((j - 1))
  done
  rename_sources[j + 1]="$key_source"
  rename_destinations[j + 1]="$key_destination"
  rename_source_relatives[j + 1]="$key_source_relative"
  rename_destination_relatives[j + 1]="$key_destination_relative"
  rename_depths[j + 1]="$key_depth"
done

claude_template="$repo_root/.claude/settings.json.template"
claude_settings="$repo_root/.claude/settings.json"
activate_claude_settings=0
if entry_exists "$claude_template"; then
  [ -f "$claude_template" ] || die "expected .claude/settings.json.template to be a file before initialization."
  activate_claude_settings=1
fi

collision_messages=()
planned_targets=()
planned_target_sources=()
collision_count=0
planned_target_count=0
for ((i = 0; i < rename_count; i++)); do
  if entry_exists "${rename_destinations[i]}"; then
    collision_messages+=("destination '${rename_destination_relatives[i]}' already exists (source '${rename_source_relatives[i]}')")
    collision_count=$((collision_count + 1))
  fi
  for ((j = 0; j < planned_target_count; j++)); do
    if [ "${planned_targets[j]}" = "${rename_destinations[i]}" ]; then
      collision_messages+=("destination '${rename_destination_relatives[i]}' is planned by multiple sources: '${planned_target_sources[j]}', '${rename_source_relatives[i]}'")
      collision_count=$((collision_count + 1))
    fi
  done
  planned_targets[planned_target_count]="${rename_destinations[i]}"
  planned_target_sources[planned_target_count]="${rename_source_relatives[i]}"
  planned_target_count=$((planned_target_count + 1))
done
if ((activate_claude_settings == 1)); then
  settings_source_relative="${claude_template#"$repo_root"/}"
  settings_destination_relative="${claude_settings#"$repo_root"/}"
  if entry_exists "$claude_settings"; then
    collision_messages+=("destination '$settings_destination_relative' already exists (source '$settings_source_relative')")
    collision_count=$((collision_count + 1))
  fi
  for ((j = 0; j < planned_target_count; j++)); do
    if [ "${planned_targets[j]}" = "$claude_settings" ]; then
      collision_messages+=("destination '$settings_destination_relative' is planned by multiple sources: '${planned_target_sources[j]}', '$settings_source_relative'")
      collision_count=$((collision_count + 1))
    fi
  done
fi

if ((collision_count > 0)); then
  printf '%s\n' 'error: initialization collision preflight failed; no files were changed:' >&2
  for message in "${collision_messages[@]}"; do
    printf '  %s\n' "$message" >&2
  done
  exit 1
fi

# Validate the template-only content edit during preflight, not after earlier
# token replacements. The same checked transform is executed below.
if ! awk '
  /^[[:space:]]*# template-only-init-security: begin[[:space:]]*$/ {
    if (inside || seen) exit 42
    inside = 1
    seen = 1
    next
  }
  /^[[:space:]]*# template-only-init-security: end[[:space:]]*$/ {
    if (!inside) exit 42
    inside = 0
    next
  }
  END { if (inside || seen != 1) exit 42 }
' "$ci_workflow" > /dev/null; then
  die "expected exactly one template-only init-security block in .github/workflows/ci.yml"
fi

# Literal, backslash-safe token replacement. The source text and the six values
# are passed through the environment because awk's ENVIRON does NO escape
# processing — unlike bash's `${var//pat/repl}`, which collapses the doubled
# backslashes toml_escape adds (`\\`->`\` on bash >= 4.3; bash 3.2 leaves them,
# so it is also version-dependent) and would emit a Cargo.toml that fails to
# parse on any backslash. The whole file is handled in BEGIN via ENVIRON so no
# record splitting can add or drop a trailing newline.
substitute_tokens() {
  awk '
    function repl(s, tok, val,   out, i) {
      out = ""
      while ((i = index(s, tok)) > 0) {
        out = out substr(s, 1, i - 1) val
        s = substr(s, i + length(tok))
      }
      return out s
    }
    BEGIN {
      s = ENVIRON["TPL_SRC"]
      s = repl(s, "__ProjectName__", ENVIRON["TPL_PROJECT"])
      s = repl(s, "__Author__",      ENVIRON["TPL_AUTHOR"])
      s = repl(s, "__AuthorEmail__", ENVIRON["TPL_AUTHOR_EMAIL"])
      s = repl(s, "__GitHubOwner__", ENVIRON["TPL_OWNER"])
      s = repl(s, "__Description__", ENVIRON["TPL_DESC"])
      s = repl(s, "__Year__",        ENVIRON["TPL_YEAR"])
      printf "%s", s
    }'
}

# 1) Replace tokens in file contents. Both initializers are skipped: they carry
#    the literal token strings as search keys, so substituting inside them would
#    corrupt the sibling script.
changed=0
for ((i = 0; i < content_count; i++)); do
  file="${content_files[i]}"
  case "$file" in
    *.toml) c=$crate_t; a=$author_t; ae=$author_email_t; o=$owner_t; d=$desc_t; y=$year_t ;;
    *)      c=$crate_name; a=$author; ae=$author_email; o=$github_owner; d=$description; y=$year ;;
  esac
  # Preserve trailing newlines: append a sentinel before capture, strip it after.
  content="$(cat "$file"; printf x)"; content="${content%x}"
  if [ "$file" = "$release_workflow" ]; then
    a="$author_release"
    ae="$author_email_release"
  fi
  new="$(TPL_SRC="$content" TPL_PROJECT="$c" TPL_AUTHOR="$a" TPL_AUTHOR_EMAIL="$ae" \
         TPL_OWNER="$o" TPL_DESC="$d" TPL_YEAR="$y" substitute_tokens; printf x)"
  new="${new%x}"
  if [ "$new" != "$content" ]; then
    printf '%s' "$new" > "$file"
    changed=$((changed + 1))
  fi
done
echo "    Updated contents in $changed file(s)."

# The security harness tests the template's initializer implementation. It is
# not a downstream project check, so remove its workflow block together with
# the harness instead of leaving a CI step that targets deleted init scripts.
ci_without_template_step="$ci_workflow.template-only.$$"
if ! awk '
  /^[[:space:]]*# template-only-init-security: begin[[:space:]]*$/ {
    if (inside || seen) exit 42
    inside = 1
    seen = 1
    next
  }
  /^[[:space:]]*# template-only-init-security: end[[:space:]]*$/ {
    if (!inside) exit 42
    inside = 0
    next
  }
  !inside { print }
  END { if (inside || seen != 1) exit 42 }
' "$ci_workflow" > "$ci_without_template_step"; then
  rm -f "$ci_without_template_step"
  die "expected exactly one template-only init-security block in .github/workflows/ci.yml"
fi
mv -f "$ci_without_template_step" "$ci_workflow"

# 2) Execute the already validated one-to-one rename plan without overwrite.
for ((i = 0; i < rename_count; i++)); do
  if entry_exists "${rename_destinations[i]}"; then
    die "destination '${rename_destination_relatives[i]}' appeared after preflight; refusing to rename source '${rename_source_relatives[i]}'."
  fi
  mv -n "${rename_sources[i]}" "${rename_destinations[i]}"
  if entry_exists "${rename_sources[i]}"; then
    die "non-overwriting rename refused destination '${rename_destination_relatives[i]}' for source '${rename_source_relatives[i]}'."
  fi
  echo "    Renamed ${rename_sources[i]##*/} -> ${rename_destinations[i]##*/}"
done

# 3) Activate Claude Code shared settings from the shipped .template (renames
#    .claude/settings.json.template -> .claude/settings.json).
if ((activate_claude_settings == 1)); then
  if entry_exists "$claude_settings"; then
    die "destination '.claude/settings.json' appeared after preflight; refusing to activate source '.claude/settings.json.template'."
  fi
  mv -n "$claude_template" "$claude_settings"
  if entry_exists "$claude_template"; then
    die "non-overwriting settings activation refused destination '.claude/settings.json'."
  fi
  echo "    Activated .claude/settings.json"
fi

# 4) Remove template-only files (the agent guide is template meta — pitfalls are
#    logged back to the *template's* copy, so the downstream repo drops it).
rm -f "$repo_root/TEMPLATE.md" "$repo_root/docs/AGENT-INIT-GUIDE.md"
rm -rf "$security_tests"
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
