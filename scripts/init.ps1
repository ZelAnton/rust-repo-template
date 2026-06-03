#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Initializes this template into a concrete Rust project.

.DESCRIPTION
    POSIX counterpart: scripts/init.sh — use whichever matches your shell.

    Replaces the placeholder tokens (__ProjectName__, __Author__, __AuthorEmail__,
    __GitHubOwner__, __Description__, __Year__) in file contents AND in file/folder
    names, then removes the template-only files (TEMPLATE.md,
    docs/AGENT-INIT-GUIDE.md, and — unless -KeepScript — both initializers,
    init.ps1 and init.sh).

    Run it once, right after creating a repository from the template:

        pwsh ./scripts/init.ps1 -ProjectName my-tool

    Omitted optional values fall back to sensible defaults so the result always
    builds; edit LICENSE / Cargo.toml afterwards if you need to refine them.

.PARAMETER ProjectName
    Project name. Required. A crates.io-legal crate name is *derived* from it
    (lowercased, runs of non-alphanumerics collapsed to '-', leading/trailing
    '-' trimmed) — e.g. "Acme.Widgets" -> "acme-widgets". That derived slug is
    what gets substituted for EVERY __ProjectName__ token: the crate name, the
    `repository` URL in Cargo.toml, and any token-named files/folders (the
    original casing is never used verbatim). The derived name must start with a
    letter (cargo rejects a leading digit); init errors if it does not. Name your
    GitHub repo with the same slug, or edit Cargo.toml's `repository` to match
    your real remote.

.PARAMETER Author
    Author for LICENSE. Defaults to `git config user.name`, else "Your Name".

.PARAMETER AuthorEmail
    Author email for the release commit. Defaults to `git config user.email`, else "you@example.com".

.PARAMETER GitHubOwner
    GitHub owner/org used in repository URLs. Defaults to "your-org".

.PARAMETER Description
    Short crate description. Defaults to "TODO: crate description".

.PARAMETER Year
    Copyright year. Defaults to the current year.

.PARAMETER KeepScript
    Keep both initializers (init.ps1 and init.sh) after running. TEMPLATE.md and
    docs/AGENT-INIT-GUIDE.md are removed either way.

.EXAMPLE
    pwsh ./scripts/init.ps1 -ProjectName my-tool -Author "Jane Doe" -GitHubOwner acme -Description "A small tool"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectName,
    [string]$Author,
    [string]$AuthorEmail,
    [string]$GitHubOwner,
    [string]$Description,
    [int]$Year = (Get-Date).Year,
    [switch]$KeepScript
)

$ErrorActionPreference = 'Stop'

# Derive a crates.io-legal crate name from the project name: lowercase, collapse
# runs of non-alphanumerics to '-', trim leading/trailing '-'. crates.io accepts
# ASCII alphanumerics plus '-' and '_'; this slug stays within that set.
$crateSafe = ($ProjectName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
if (-not $crateSafe) {
    throw "Invalid -ProjectName '$ProjectName'. It must contain at least one ASCII letter or digit so a crate name can be derived (e.g. my-tool)."
}
# cargo rejects a crate name that starts with a digit ("the name cannot start
# with a digit"). The slug derivation above can't fix that, so fail clearly here
# rather than emitting a Cargo.toml that won't build.
if ($crateSafe -notmatch '^[a-z]') {
    throw "Invalid -ProjectName '$ProjectName' -> derived crate name '$crateSafe' starts with a non-letter; cargo requires a crate name that starts with a letter. Pick a project name whose first alphanumeric is a letter (e.g. my-tool)."
}

if (-not $Author) {
    $Author = (& git config user.name 2>$null)
    if (-not $Author) { $Author = 'Your Name' }
}
if (-not $AuthorEmail) {
    $AuthorEmail = (& git config user.email 2>$null)
    if (-not $AuthorEmail) { $AuthorEmail = 'you@example.com' }
}
if (-not $GitHubOwner) { $GitHubOwner = 'your-org' }
if (-not $Description) { $Description = 'TODO: crate description' }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$selfPath = $PSCommandPath

$replacements = [ordered]@{
    '__ProjectName__' = $crateSafe
    '__Author__'      = $Author
    '__AuthorEmail__' = $AuthorEmail
    '__GitHubOwner__' = $GitHubOwner
    '__Description__'  = $Description
    '__Year__'        = "$Year"
}

# Values written into TOML files (Cargo.toml description/repository) sit inside
# double-quoted strings — a literal " or \ in an author/description would break
# the manifest, so escape them for .toml targets.
$tomlReplacements = [ordered]@{}
foreach ($key in $replacements.Keys) {
    $tomlReplacements[$key] = $replacements[$key].Replace('\', '\\').Replace('"', '\"')
}
$tomlFileExtensions = @('.toml')

$excludedDirs = @('.git', '.jj', 'target')

function Test-Excluded([string]$fullPath) {
    $rel = $fullPath.Substring($repoRoot.Length).TrimStart('\', '/')
    foreach ($seg in ($rel -split '[\\/]')) {
        if ($excludedDirs -contains $seg) { return $true }
    }
    return $false
}

Write-Host "==> Initializing template as '$crateSafe'" -ForegroundColor Cyan

# 1) Replace tokens in file contents. Both initializers are skipped: they carry
#    the literal token strings as search keys, so substituting inside them would
#    corrupt the sibling script.
$siblingSh = Join-Path $PSScriptRoot 'init.sh'
$files = Get-ChildItem -Path $repoRoot -File -Recurse | Where-Object {
    -not (Test-Excluded $_.FullName) -and $_.FullName -ne $selfPath -and $_.FullName -ne $siblingSh
}
$contentChanged = 0
foreach ($file in $files) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    $new = $text
    $map = if ($tomlFileExtensions -contains $file.Extension) { $tomlReplacements } else { $replacements }
    foreach ($key in $map.Keys) {
        $new = $new.Replace($key, $map[$key])
    }
    if ($new -ne $text) {
        # UTF-8 without BOM, LF preserved — matches .gitattributes (eol=lf).
        [System.IO.File]::WriteAllText($file.FullName, $new, (New-Object System.Text.UTF8Encoding($false)))
        $contentChanged++
    }
}
Write-Host "    Updated contents in $contentChanged file(s)." -ForegroundColor DarkGray

# 2) Rename files and folders whose name contains the crate-name token.
#    Deepest paths first so child renames don't invalidate parent paths.
#    (The single-crate skeleton has none, but workspace adaptations may add
#    `crates/__ProjectName__` etc., so support it.)
$named = Get-ChildItem -Path $repoRoot -Recurse | Where-Object {
    -not (Test-Excluded $_.FullName) -and $_.Name -like '*__ProjectName__*'
} | Sort-Object { $_.FullName.Length } -Descending
foreach ($item in $named) {
    $newName = $item.Name.Replace('__ProjectName__', $crateSafe)
    Rename-Item -LiteralPath $item.FullName -NewName $newName
    Write-Host "    Renamed $($item.Name) -> $newName" -ForegroundColor DarkGray
}

# 3) Activate Claude Code shared settings from the shipped .template (renames
#    .claude/settings.json.template -> .claude/settings.json).
$claudeTemplate = Join-Path $repoRoot '.claude/settings.json.template'
if (Test-Path $claudeTemplate) {
    Move-Item -LiteralPath $claudeTemplate -Destination (Join-Path $repoRoot '.claude/settings.json') -Force
    Write-Host "    Activated .claude/settings.json" -ForegroundColor DarkGray
}

# 4) Remove template-only files. The agent guide is template meta — pitfalls are
#    logged back to the *template's* copy (see the guide), so the downstream repo
#    doesn't keep it.
$templateOnly = @('TEMPLATE.md', 'docs/AGENT-INIT-GUIDE.md')
foreach ($rel in $templateOnly) {
    $p = Join-Path $repoRoot $rel
    if (Test-Path $p) { Remove-Item -LiteralPath $p -Force }
}
# Drop docs/ if it's now empty.
$docsDir = Join-Path $repoRoot 'docs'
if ((Test-Path $docsDir) -and -not (Get-ChildItem -LiteralPath $docsDir -Force)) {
    Remove-Item -LiteralPath $docsDir -Force
}

Write-Host ""
Write-Host "Done. Next steps:" -ForegroundColor Green
Write-Host "  1. cargo build && cargo test"
Write-Host "  2. cargo clippy --all-targets -- -D warnings && cargo fmt --all --check"
Write-Host "  3. Review LICENSE (author/year) and Cargo.toml metadata."
Write-Host "  4. Replace src/main.rs (and tests/integration.rs) with your code,"
Write-Host "     or switch to a library crate (src/lib.rs)."
Write-Host "  5. Fill the Project section of AGENTS.md, then commit."

# Remove both initializers unless asked to keep them.
if (-not $KeepScript) {
    if (Test-Path $siblingSh) { Remove-Item -LiteralPath $siblingSh -Force }
    Remove-Item -LiteralPath $selfPath -Force
}
