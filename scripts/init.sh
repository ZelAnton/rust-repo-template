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
#
# Path names use the same six-token contract as file contents. Each token is
# matched once against the original name and replaced with its opaque value;
# the value must be one non-empty portable filename component (no separators,
# controls, Windows-invalid characters, or trailing space/dot). An unknown
# token or unsafe value aborts before any mutation.
# Every value-bearing option requires a value before another option; --year is
# a signed decimal 32-bit integer, matching the PowerShell [int] contract.

set -euo pipefail

project_name=""
author=""
author_email=""
github_owner=""
description=""
year=""
keep_script=0

die() { echo "error: $*" >&2; exit 1; }

read_option_value() {
  local option="$1"
  if [ "$#" -lt 2 ]; then
    die "$option requires a value. No files were changed."
  fi
  case "$2" in
    -*)
      if [ "$option" = "--year" ]; then
        case "$2" in
          --*|-h|-x) die "$option requires a value before option '$2'. No files were changed." ;;
          *) ;;
        esac
      else
        die "$option requires a value before option '$2'. No files were changed."
      fi
      ;;
  esac
  option_value="$2"
}

validate_year() {
  local value="$1"
  local normalized

  # PowerShell's [int] binder first parses a numeric string, rounds a decimal
  # value to the nearest Int32 (ties to even), and emits canonical decimal
  # text. Keep that contract without relying on shell arithmetic overflow.
  if ! normalized="$(LC_ALL=C TPL_YEAR="$value" awk '
    function fail() { exit 1 }
    BEGIN {
      value = ENVIRON["TPL_YEAR"]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value == "") { print "0"; exit 0 }
      gsub(/,/, "", value)
      if (value !~ /^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/) fail()
      number = value + 0
      if (number != number || number > 2147483648 || number < -2147483648) fail()
      result = sprintf("%.0f", number)
      if (result == "-0") result = "0"
      if (result > 2147483647 || result < -2147483648) fail()
      print result
    }')"; then
    die "invalid --year '$value'. Use a PowerShell-compatible signed numeric 32-bit integer. No files were changed."
  fi
  year="$normalized"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project-name) read_option_value "$@"; project_name="$option_value"; shift 2 ;;
    --author)       read_option_value "$@"; author="$option_value"; shift 2 ;;
    --author-email) read_option_value "$@"; author_email="$option_value"; shift 2 ;;
    --github-owner) read_option_value "$@"; github_owner="$option_value"; shift 2 ;;
    --description)  read_option_value "$@"; description="$option_value"; shift 2 ;;
    --year)         read_option_value "$@"; validate_year "$option_value"; shift 2 ;;
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

supported_path_tokens='__ProjectName__ __Author__ __AuthorEmail__ __GitHubOwner__ __Description__ __Year__'

is_safe_path_replacement() {
  path_value="$1"
  [ -n "$path_value" ] || return 1
  [ "$path_value" != "." ] && [ "$path_value" != ".." ] || return 1
  case "$path_value" in
    *[[:cntrl:]]*|*'/'*|*\\*|*'<'*|*'>'*|*':'*|*'"'*|*'|'*|*'?'*|*'*'*) return 1 ;;
  esac
  # Leading and internal spaces are portable; only a trailing space or dot is
  # rejected because Windows trims those characters from path components.
  case "$path_value" in
    *' '|*.) return 1 ;;
  esac
  # Device names are reserved only when they are the complete basename. An
  # optional dot extension is part of the same basename contract, so CON.foo
  # is unsafe while CONtext and COM10 remain valid values.
  path_reserved_base="${path_value%%.*}"
  case "$path_reserved_base" in
    [cC][oO][nN]|[pP][rR][nN]|[aA][uU][xX]|[nN][uU][lL]|[cC][oO][mM][1-9]|[lL][pP][tT][1-9]) return 1 ;;
  esac
  return 0
}

path_replacement_for() {
  case "$1" in
    __ProjectName__) path_replacement_value="$crate_name" ;;
    __Author__) path_replacement_value="$author" ;;
    __AuthorEmail__) path_replacement_value="$author_email" ;;
    __GitHubOwner__) path_replacement_value="$github_owner" ;;
    __Description__) path_replacement_value="$description" ;;
    __Year__) path_replacement_value="$year" ;;
    *) return 1 ;;
  esac
}

expand_path_name_single_pass() {
  path_name_input="$1"
  path_name_source="$2"
  path_name_output=""
  path_name_remainder="$path_name_input"
  path_name_unchecked="$path_name_input"
  while [[ "$path_name_unchecked" =~ (__ProjectName__|__Author__|__AuthorEmail__|__GitHubOwner__|__Description__|__Year__) ]]; do
    path_name_unchecked="${path_name_unchecked#*"${BASH_REMATCH[1]}"}"
  done
  if [[ "$path_name_unchecked" =~ (__.+__) ]]; then
    path_name_token="${BASH_REMATCH[1]}"
    die "unsupported path token '$path_name_token' in '$path_name_source'; supported tokens are $supported_path_tokens; no files were changed."
  fi
  while [[ "$path_name_remainder" =~ (__ProjectName__|__Author__|__AuthorEmail__|__GitHubOwner__|__Description__|__Year__) ]]; do
    path_name_token="${BASH_REMATCH[1]}"
    path_name_prefix="${path_name_remainder%%"$path_name_token"*}"
    path_replacement_for "$path_name_token" ||
      die "unsupported path token '$path_name_token' in '$path_name_source'; supported tokens are $supported_path_tokens; no files were changed."
    is_safe_path_replacement "$path_replacement_value" ||
      die "unsupported or unsafe path token '$path_name_token' in '$path_name_source': replacement must be a non-empty portable filename component (no separators, controls, Windows-invalid characters, or trailing space/dot); no files were changed."
    path_name_output+="$path_name_prefix$path_replacement_value"
    path_name_remainder="${path_name_remainder#*"$path_name_token"}"
  done
  path_name_expanded="$path_name_output$path_name_remainder"
}

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

# Tokens in .toml templates are basic-string content, not complete TOML values.
# Use TOML's short escapes where available. Reject the remaining C0 controls and
# DEL before creating the transaction directory rather than emitting a manifest
# whose meaning depends on a parser's handling of literal controls.
toml_escape() {
  local parameter_name="$1"
  local input="$2"
  local character code_point display index
  toml_escaped=""

  # Byte-wise iteration leaves valid UTF-8 bytes untouched and makes every
  # forbidden ASCII control observable independent of the caller's locale.
  local LC_ALL=C
  for ((index = 0; index < ${#input}; index++)); do
    character="${input:index:1}"
    case "$character" in
      $'\b') toml_escaped+='\b' ;;
      $'\t') toml_escaped+='\t' ;;
      $'\n') toml_escaped+='\n' ;;
      $'\f') toml_escaped+='\f' ;;
      $'\r') toml_escaped+='\r' ;;
      '"')   toml_escaped+='\"' ;;
      '\')   toml_escaped+='\\' ;;
      *)
        printf -v code_point '%d' "'$character"
        if ((code_point <= 31 || code_point == 127)); then
          printf -v display 'U+%04X' "$code_point"
          die "invalid $parameter_name: control character $display is unsupported in TOML string input; no files were changed."
        fi
        toml_escaped+="$character"
        ;;
    esac
  done
}

# Keep TOML serialization separate from ordinary text substitution so
# Markdown, YAML, and paths still receive the original value.
toml_escape --author "$author"; author_t="$toml_escaped"
toml_escape --author-email "$author_email"; author_email_t="$toml_escaped"
toml_escape --github-owner "$github_owner"; owner_t="$toml_escaped"
toml_escape --description "$description"; desc_t="$toml_escaped"
toml_escape --project-name "$crate_name"; crate_t="$toml_escaped"
toml_escape --year "$year"; year_t="$toml_escaped"

echo "==> Initializing template as '$crate_name'"

entry_exists() { [ -e "$1" ] || [ -L "$1" ]; }

transaction_dir="$(mktemp -d "${TMPDIR:-/tmp}/rust-template-init.XXXXXX")" ||
  die "could not create initializer transaction directory."

# A content source is safe to open through its repository path only while it is
# a regular non-symlink with exactly one hard link. Re-run this observable
# contract immediately before every content write and rollback restore; the
# initial inventory alone cannot protect against a post-preflight substitution.
ordinary_file() {
  ordinary_path="$1"
  ordinary_probe="$transaction_dir/ordinary-file-probe"
  [ ! -L "$ordinary_path" ] && [ -f "$ordinary_path" ] || return 1
  find "$ordinary_path" -prune -links 1 -print > "$ordinary_probe" || return 1
  [ -s "$ordinary_probe" ]
}

transaction_active=0
transaction_committed=0
completed_rename_indices=()
completed_rename_count=0
settings_was_activated=0
content_plan_files=()
content_plan_originals=()
content_plan_updates=()
content_plan_count=0
completed_content_count=0

rollback_transaction() {
  rollback_failed=0

  if ((settings_was_activated == 1)); then
    if entry_exists "$claude_template" && entry_exists "$claude_settings"; then
      : # The planned move never ran; the destination belongs to the racer.
    elif entry_exists "$claude_template" && ! entry_exists "$claude_settings"; then
      : # The planned move never ran and there is nothing to undo.
    elif entry_exists "$claude_settings" && mv -n "$claude_settings" "$claude_template"; then
      :
    else
      printf '%s\n' 'error: rollback could not restore .claude/settings.json.template' >&2
      rollback_failed=1
    fi
  fi

  for ((rollback_i = completed_rename_count - 1; rollback_i >= 0; rollback_i--)); do
    plan_i="${completed_rename_indices[rollback_i]}"
    if entry_exists "${rename_sources[plan_i]}"; then
      : # The planned move never ran; leave any race-created destination alone.
    elif entry_exists "${rename_destinations[plan_i]}" &&
         mv -n "${rename_destinations[plan_i]}" "${rename_sources[plan_i]}"; then
      :
    else
      printf "error: rollback could not restore source '%s'\n" \
        "${rename_source_relatives[plan_i]}" >&2
      rollback_failed=1
    fi
  done

  for ((rollback_i = 0; rollback_i < completed_content_count; rollback_i++)); do
    if ! ordinary_file "${content_plan_files[rollback_i]}" ||
       ! cp "${content_plan_originals[rollback_i]}" "${content_plan_files[rollback_i]}"; then
      printf "error: rollback could not restore content '%s'\n" \
        "${content_plan_files[rollback_i]#"$repo_root"/}" >&2
      rollback_failed=1
    fi
  done

  return "$rollback_failed"
}

finish_initializer() {
  status=$?
  trap - EXIT HUP INT TERM
  if ((status != 0 && transaction_active == 1 && transaction_committed == 0)); then
    set +e
    if ! rollback_transaction; then
      printf '%s\n' 'error: initialization rollback was incomplete' >&2
    fi
  fi
  rm -rf "$transaction_dir"
  exit "$status"
}

trap 'finish_initializer' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Build and validate one complete inventory before any repository mutation. The
# arrays deliberately use Bash 3-compatible indexed arrays so the initializer
# retains macOS support. find includes dot-prefixed entries by default, does not
# follow links, and prunes VCS/build directories before their children are
# visited; each remaining link and non-regular entry is rejected before any
# target path is opened.
inventory_manifest="$transaction_dir/repository-entries"
traversal_failure="${INIT_SECURITY_TEST_FAIL_TRAVERSAL:-}"
if [ "$traversal_failure" = content ] || [ "$traversal_failure" = rename ]; then
  printf '%s\0' "$repo_root/Cargo.toml" > "$inventory_manifest"
  inventory_find_status=73
elif find "$repo_root" \
    \( \( -name .git -o -name .jj -o -name target \) -o -path "$security_tests" \) -prune \
    -o -print0 > "$inventory_manifest"; then
  inventory_find_status=0
else
  inventory_find_status=$?
fi
if ((inventory_find_status != 0)); then
  if [ "$traversal_failure" = content ] || [ "$traversal_failure" = rename ]; then
    die "could not traverse the complete repository $traversal_failure tree; no files were changed."
  fi
  die "could not traverse the complete repository input tree; no files were changed."
fi

content_files=()
content_count=0
rename_sources=()
rename_destinations=()
rename_source_relatives=()
rename_destination_relatives=()
rename_depths=()
rename_count=0
unsafe_messages=()
unsafe_count=0
while IFS= read -r -d '' item; do
  [ "$item" != "$repo_root" ] || continue
  source_relative="${item#"$repo_root"/}"
  if [ -L "$item" ]; then
    unsafe_messages+=("'$source_relative' is a link or reparse point")
    unsafe_count=$((unsafe_count + 1))
    continue
  elif [ -d "$item" ]; then
    :
  elif [ -f "$item" ]; then
    if ! ordinary_file "$item"; then
      unsafe_messages+=("'$source_relative' is a link or reparse point")
      unsafe_count=$((unsafe_count + 1))
      continue
    fi
    case "$item" in
      "$self"|"$sibling_ps1") ;;
      *)
        content_files[content_count]="$item"
        content_count=$((content_count + 1))
        ;;
    esac
  else
    unsafe_messages+=("'$source_relative' is not a regular file or directory")
    unsafe_count=$((unsafe_count + 1))
    continue
  fi

  base="${item##*/}"
  expand_path_name_single_pass "$base" "$source_relative"
  newbase="$path_name_expanded"
  if [[ "$newbase" != "$base" ]]; then
    dir="${item%/*}"
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
  fi
done < "$inventory_manifest"

if ((unsafe_count > 0)); then
  printf '%s\n' 'error: initialization input preflight rejected unsafe filesystem entries; no files were changed:' >&2
  for message in "${unsafe_messages[@]}"; do
    printf '  %s\n' "$message" >&2
  done
  exit 1
fi

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

# Deepest sources run first; equal-depth paths use lexical order. This mirrors
# init.ps1 and prevents a parent rename from invalidating an unprocessed child.
# Every advertised token is expanded from the original name; unknown tokens and
# unsafe replacement values fail this preflight before content is staged.
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

# Both initializers use the same byte-level contract: only ordinary files that
# are valid UTF-8 and contain no NUL byte are eligible for token replacement.
# Binary (NUL-containing) and unsupported (invalid UTF-8) regular files remain
# byte-for-byte unchanged. Required template control files must be supported so
# initialization cannot silently produce a broken repository.
command -v iconv > /dev/null 2>&1 ||
  die "iconv is required to classify UTF-8 template files; no files were changed."

# The source file is read by awk through stdin. Only the small replacement map
# and one trailing-newline flag enter the process environment, so a large file
# never becomes argv or environment data. awk preserves CR bytes inside CRLF
# records; explicitly restoring the final LF distinguishes a terminated last
# record from an unterminated one without capturing file content in Bash.
substitute_tokens() {
  substitute_source="$1"
  substitute_last_byte="$(LC_ALL=C tail -c 1 "$substitute_source" | od -An -tu1 | tr -d '[:space:]')"
  substitute_trailing_lf=0
  [ "$substitute_last_byte" != 10 ] || substitute_trailing_lf=1
  TPL_TRAILING_LF="$substitute_trailing_lf" awk '
    BEGIN {
      replacement["__ProjectName__"] = ENVIRON["TPL_PROJECT"]
      replacement["__Author__"] = ENVIRON["TPL_AUTHOR"]
      replacement["__AuthorEmail__"] = ENVIRON["TPL_AUTHOR_EMAIL"]
      replacement["__GitHubOwner__"] = ENVIRON["TPL_OWNER"]
      replacement["__Description__"] = ENVIRON["TPL_DESC"]
      replacement["__Year__"] = ENVIRON["TPL_YEAR"]
    }
    function expand_original(s,   out, matched) {
      out = ""
      while (match(s, /__(ProjectName|Author|AuthorEmail|GitHubOwner|Description|Year)__/)) {
        matched = substr(s, RSTART, RLENGTH)
        out = out substr(s, 1, RSTART - 1) replacement[matched]
        s = substr(s, RSTART + RLENGTH)
      }
      return out s
    }
    {
      # Only the untouched source remainder is matched; appended replacement
      # values are output data and can never become a second template pass.
      s = expand_original($0)
      if (NR > 1) printf "\n"
      printf "%s", s
    }
    END { if (ENVIRON["TPL_TRAILING_LF"] == "1") printf "\n" }
  ' "$substitute_source"
}

# Materialize every supported transform in the external transaction directory
# before reserving or changing a path in the repository. Snapshots also make a
# later rollback byte-for-byte.
mkdir -p "$transaction_dir/originals" "$transaction_dir/updates"
for ((i = 0; i < content_count; i++)); do
  file="${content_files[i]}"
  original="$transaction_dir/originals/$i"
  update="$transaction_dir/updates/$i"
  candidate="$transaction_dir/candidate-$i"
  classification_file="$transaction_dir/classification-$i"

  if ! ordinary_file "$file"; then
    die "content source '${file#"$repo_root"/}' changed during input preflight; refusing to read through it."
  fi
  if ! LC_ALL=C od -An -v -tu1 "$file" | awk '
      { for (field = 1; field <= NF; field++) if ($field == 0) binary = 1 }
      END { print binary ? "binary" : "text" }
    ' > "$classification_file"; then
    die "could not classify '${file#"$repo_root"/}' during input preflight; no files were changed."
  fi
  IFS= read -r classification < "$classification_file" ||
    die "could not read the classification for '${file#"$repo_root"/}'; no files were changed."

  required_text=0
  case "$file" in
    "$release_workflow"|"$ci_workflow"|"$repo_root/Cargo.toml") required_text=1 ;;
  esac
  if [ "$classification" = binary ]; then
    ((required_text == 0)) ||
      die "required template file '${file#"$repo_root"/}' is binary (contains NUL); no files were changed."
    continue
  fi
  if ! iconv -f UTF-8 -t UTF-8 "$file" > /dev/null; then
    ((required_text == 0)) ||
      die "required template file '${file#"$repo_root"/}' is unsupported (not valid UTF-8); no files were changed."
    continue
  fi
  if ! cp "$file" "$original"; then
    die "could not snapshot '${file#"$repo_root"/}' during preflight; no files were changed."
  fi

  case "$file" in
    *.toml) c=$crate_t; a=$author_t; ae=$author_email_t; o=$owner_t; d=$desc_t; y=$year_t ;;
    *)      c=$crate_name; a=$author; ae=$author_email; o=$github_owner; d=$description; y=$year ;;
  esac
  if [ "$file" = "$release_workflow" ]; then
    a="$author_release"
    ae="$author_email_release"
  fi
  if ! TPL_PROJECT="$c" TPL_AUTHOR="$a" TPL_AUTHOR_EMAIL="$ae" \
       TPL_OWNER="$o" TPL_DESC="$d" TPL_YEAR="$y" \
       substitute_tokens "$original" > "$candidate"; then
    die "could not transform '${file#"$repo_root"/}' during preflight; no files were changed."
  fi

  if [ "$file" = "$ci_workflow" ]; then
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
    ' "$candidate" > "$update"; then
      die "expected exactly one template-only init-security block in .github/workflows/ci.yml"
    fi
  elif ! mv "$candidate" "$update"; then
    die "could not stage '${file#"$repo_root"/}' during preflight; no files were changed."
  fi

  if cmp -s "$original" "$update"; then
    rm -f "$original" "$update" "$candidate"
  else
    compare_status=$?
    if ((compare_status > 1)); then
      die "could not compare staged content for '${file#"$repo_root"/}'; no files were changed."
    fi
    content_plan_files[content_plan_count]="$file"
    content_plan_originals[content_plan_count]="$original"
    content_plan_updates[content_plan_count]="$update"
    content_plan_count=$((content_plan_count + 1))
  fi
done

collision_messages=()
collision_count=0
reservation_paths=()
reservation_relatives=()
reservation_sources=()
reservation_marker_names=()
reservation_marker_paths=()
reservation_marker_created=()
reservation_count=0

wait_reservation_cleanup_checkpoint() {
  checkpoint_relative="$1"
  checkpoint_kind="$2"
  if [ "$checkpoint_kind" = partial ]; then
    checkpoint_held_destination="${INIT_SECURITY_TEST_HOLD_AFTER_PARTIAL_RESERVATION_MARKER_FAILURE:-}"
    checkpoint_message=INITIALIZER_TEST_PARTIAL_RESERVATION_MARKER_FAILED
  else
    checkpoint_held_destination="${INIT_SECURITY_TEST_HOLD_AFTER_RESERVATION_OWNERSHIP_CHECK:-}"
    checkpoint_message=INITIALIZER_TEST_RESERVATION_OWNERSHIP_CHECKED
  fi
  if [ "$checkpoint_held_destination" != "$checkpoint_relative" ]; then
    return 0
  fi

  printf '%s\n' "$checkpoint_message"
  if [ -n "${INIT_SECURITY_TEST_READY_FILE:-}" ] &&
     [ -n "${INIT_SECURITY_TEST_RELEASE_FILE:-}" ]; then
    printf '%s' ready > "$INIT_SECURITY_TEST_READY_FILE"
    checkpoint_waits=0
    while ! entry_exists "$INIT_SECURITY_TEST_RELEASE_FILE"; do
      ((checkpoint_waits < 1500)) || die "initializer reservation cleanup checkpoint was not released."
      sleep 0.02
      checkpoint_waits=$((checkpoint_waits + 1))
    done
  elif ! IFS= read -r checkpoint_release || [ "$checkpoint_release" != continue ]; then
    die "initializer reservation cleanup checkpoint was not released."
  fi
}

reserve_destination() {
  reservation_path="$1"
  reservation_relative="$2"
  reservation_source="$3"
  reservation_marker_name=".rust-template-init-reservation-${transaction_dir##*/}-$$-$reservation_count"

  # Exclusive mkdir at the exact target delegates case, Unicode, normalization,
  # and per-directory equivalence to its filesystem. Track the outer directory
  # before attempting the nested nonce so partial marker failure stays cleanable.
  if mkdir "$reservation_path" 2>/dev/null; then
    reservation_i="$reservation_count"
    reservation_paths[reservation_i]="$reservation_path"
    reservation_relatives[reservation_i]="$reservation_relative"
    reservation_sources[reservation_i]="$reservation_source"
    reservation_marker_names[reservation_i]="$reservation_marker_name"
    reservation_marker_paths[reservation_i]="$reservation_path/$reservation_marker_name"
    reservation_marker_created[reservation_i]=0
    # This increment must remain immediately after the successful outer mkdir.
    reservation_count=$((reservation_count + 1))

    if [ "${INIT_SECURITY_TEST_FAIL_RESERVATION_MARKER:-}" = "$reservation_relative" ]; then
      collision_messages+=("destination '$reservation_relative' ownership marker could not be created after reservation; no files were changed (source '$reservation_source')")
      collision_count=$((collision_count + 1))
      return
    fi

    if ! mkdir "${reservation_marker_paths[reservation_i]}" 2>/dev/null; then
      collision_messages+=("destination '$reservation_relative' ownership marker could not be created after reservation (source '$reservation_source')")
      collision_count=$((collision_count + 1))
      return
    fi
    reservation_marker_created[reservation_i]=1
    return
  fi

  reservation_owner=-1
  for ((reservation_i = 0; reservation_i < reservation_count; reservation_i++)); do
    if [ "${reservation_marker_created[reservation_i]}" = 1 ] &&
       [ -d "$reservation_path/${reservation_marker_names[reservation_i]}" ] &&
       [ ! -L "$reservation_path/${reservation_marker_names[reservation_i]}" ]; then
      reservation_owner="$reservation_i"
      break
    fi
  done

  if ((reservation_owner >= 0)); then
    collision_messages+=("destination '$reservation_relative' is planned by multiple sources: '${reservation_sources[reservation_owner]}', '$reservation_source'")
  elif entry_exists "$reservation_path"; then
    collision_messages+=("destination '$reservation_relative' already exists (source '$reservation_source')")
  else
    collision_messages+=("destination '$reservation_relative' could not be reserved; filesystem equivalence could not be established (source '$reservation_source')")
  fi
  collision_count=$((collision_count + 1))
}

for ((i = 0; i < rename_count; i++)); do
  reserve_destination \
    "${rename_destinations[i]}" \
    "${rename_destination_relatives[i]}" \
    "${rename_source_relatives[i]}"
done
if ((activate_claude_settings == 1)); then
  settings_source_relative="${claude_template#"$repo_root"/}"
  settings_destination_relative="${claude_settings#"$repo_root"/}"
  reserve_destination "$claude_settings" "$settings_destination_relative" "$settings_source_relative"
fi

# Cleanup uses only non-recursive directory removal. A replacement file,
# symlink, or non-empty directory survives and aborts before template writes.
reservation_cleanup_failed=0
for ((i = 0; i < reservation_count; i++)); do
  if [ "${reservation_marker_created[i]}" = 1 ]; then
    if [ ! -d "${reservation_marker_paths[i]}" ] || [ -L "${reservation_marker_paths[i]}" ]; then
      printf "error: destination reservation '%s' ownership marker changed before cleanup; no template files were changed\n" \
        "${reservation_relatives[i]}" >&2
      reservation_cleanup_failed=1
      continue
    fi

    wait_reservation_cleanup_checkpoint "${reservation_relatives[i]}" owned

    if ! rmdir "${reservation_marker_paths[i]}"; then
      printf "error: could not clean destination reservation '%s' ownership marker; no template files were changed\n" \
        "${reservation_relatives[i]}" >&2
      reservation_cleanup_failed=1
      continue
    fi
  else
    wait_reservation_cleanup_checkpoint "${reservation_relatives[i]}" partial
  fi

  if ! rmdir "${reservation_paths[i]}" || entry_exists "${reservation_paths[i]}"; then
    printf "error: could not clean destination reservation '%s'; no template files were changed\n" \
      "${reservation_relatives[i]}" >&2
    reservation_cleanup_failed=1
  fi
done
((reservation_cleanup_failed == 0)) || exit 1

if ((collision_count > 0)); then
  printf '%s\n' 'error: initialization collision preflight failed; no files were changed:' >&2
  for message in "${collision_messages[@]}"; do
    printf '  %s\n' "$message" >&2
  done
  exit 1
fi

if [ "${INIT_SECURITY_TEST_HOLD_AFTER_PREFLIGHT:-}" = "1" ]; then
  printf '%s\n' 'INITIALIZER_TEST_PREFLIGHT_READY'
  if [ -n "${INIT_SECURITY_TEST_READY_FILE:-}" ] &&
     [ -n "${INIT_SECURITY_TEST_RELEASE_FILE:-}" ]; then
    printf '%s' ready > "$INIT_SECURITY_TEST_READY_FILE"
    checkpoint_waits=0
    while ! entry_exists "$INIT_SECURITY_TEST_RELEASE_FILE"; do
      checkpoint_waits=$((checkpoint_waits + 1))
      ((checkpoint_waits < 600)) || die "initializer security test checkpoint was not released."
      sleep 0.05
    done
  else
    IFS= read -r checkpoint_release || die "initializer security test checkpoint was not released."
    [ "$checkpoint_release" = continue ] || die "initializer security test checkpoint was not released."
  fi
fi

transaction_active=1

# 1) Apply the staged content plan. Both initializers are skipped because they
#    carry the literal token strings as search keys.
for ((i = 0; i < content_plan_count; i++)); do
  if ! ordinary_file "${content_plan_files[i]}"; then
    die "content source '${content_plan_files[i]#"$repo_root"/}' changed after preflight; refusing to write through it."
  fi
  # cp can fail after truncating the target. Include this verified path in the
  # rollback journal immediately before attempting the mutation.
  completed_content_count=$((i + 1))
  if ! cp "${content_plan_updates[i]}" "${content_plan_files[i]}"; then
    die "could not update '${content_plan_files[i]#"$repo_root"/}'."
  fi
done
echo "    Updated contents in $content_plan_count file(s)."

# 2) Execute the already validated one-to-one rename plan without overwrite.
for ((i = 0; i < rename_count; i++)); do
  if entry_exists "${rename_destinations[i]}"; then
    die "destination '${rename_destination_relatives[i]}' appeared after preflight; refusing to rename source '${rename_source_relatives[i]}'."
  fi
  if ! mv -n "${rename_sources[i]}" "${rename_destinations[i]}" ||
     entry_exists "${rename_sources[i]}" || ! entry_exists "${rename_destinations[i]}"; then
    die "non-overwriting rename refused destination '${rename_destination_relatives[i]}' for source '${rename_source_relatives[i]}'."
  fi
  completed_rename_indices[completed_rename_count]="$i"
  completed_rename_count=$((completed_rename_count + 1))
  echo "    Renamed ${rename_sources[i]##*/} -> ${rename_destinations[i]##*/}"
done

# 3) Activate Claude Code shared settings from the shipped .template (renames
#    .claude/settings.json.template -> .claude/settings.json).
if ((activate_claude_settings == 1)); then
  if entry_exists "$claude_settings"; then
    die "destination '.claude/settings.json' appeared after preflight; refusing to activate source '.claude/settings.json.template'."
  fi
  if ! mv -n "$claude_template" "$claude_settings" || entry_exists "$claude_template" ||
     ! entry_exists "$claude_settings"; then
    die "non-overwriting settings activation refused destination '.claude/settings.json'."
  fi
  settings_was_activated=1
  echo "    Activated .claude/settings.json"
fi

transaction_committed=1

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
