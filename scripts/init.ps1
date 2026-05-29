#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Initializes this template into a concrete Rust project.

.DESCRIPTION
    Replaces the placeholder tokens (__CrateName__, __Author__, __GitHubOwner__,
    __Description__, __Year__, __Date__) in file contents AND in file/folder
    names, then removes the template-only files (TEMPLATE.md,
    docs/AGENT-INIT-GUIDE.md, and — unless -KeepScript — this script itself).

    Run it once, right after creating a repository from the template:

        pwsh ./scripts/init.ps1 -CrateName my-tool

    Omitted optional values fall back to sensible defaults so the result always
    builds; edit LICENSE / Cargo.toml afterwards if you need to refine them.

.PARAMETER CrateName
    Crate name / repository name. Required. crates.io-legal: letters, digits,
    hyphens, underscores (kebab-case recommended, e.g. my-tool).

.PARAMETER Author
    Author for LICENSE. Defaults to `git config user.name`, else "Your Name".

.PARAMETER GitHubOwner
    GitHub owner/org used in repository URLs. Defaults to "your-org".

.PARAMETER Description
    Short crate description. Defaults to "TODO: crate description".

.PARAMETER Year
    Copyright year. Defaults to the current year.

.PARAMETER Date
    Release date for the CHANGELOG 0.1.0 entry (YYYY-MM-DD). Defaults to today.

.PARAMETER KeepScript
    Keep this script after running (TEMPLATE.md is removed either way).

.EXAMPLE
    pwsh ./scripts/init.ps1 -CrateName my-tool -Author "Jane Doe" -GitHubOwner acme -Description "A small tool"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CrateName,
    [string]$Author,
    [string]$GitHubOwner,
    [string]$Description,
    [int]$Year = (Get-Date).Year,
    [string]$Date = (Get-Date).ToString('yyyy-MM-dd'),
    [switch]$KeepScript
)

$ErrorActionPreference = 'Stop'

# crates.io accepts ASCII alphanumerics plus `-` and `_`; must start with a letter.
if ($CrateName -notmatch '^[A-Za-z][A-Za-z0-9_-]*$') {
    throw "Invalid -CrateName '$CrateName'. Use letters, digits, '-' or '_'; start with a letter (e.g. my-tool)."
}

if (-not $Author) {
    $Author = (& git config user.name 2>$null)
    if (-not $Author) { $Author = 'Your Name' }
}
if (-not $GitHubOwner) { $GitHubOwner = 'your-org' }
if (-not $Description) { $Description = 'TODO: crate description' }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$selfPath = $PSCommandPath

$replacements = [ordered]@{
    '__CrateName__'   = $CrateName
    '__Author__'      = $Author
    '__GitHubOwner__' = $GitHubOwner
    '__Description__'  = $Description
    '__Year__'        = "$Year"
    '__Date__'        = $Date
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

Write-Host "==> Initializing template as '$CrateName'" -ForegroundColor Cyan

# 1) Replace tokens in file contents (this script is left untouched).
$files = Get-ChildItem -Path $repoRoot -File -Recurse | Where-Object {
    -not (Test-Excluded $_.FullName) -and $_.FullName -ne $selfPath
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
#    `crates/__CrateName__` etc., so support it.)
$named = Get-ChildItem -Path $repoRoot -Recurse | Where-Object {
    -not (Test-Excluded $_.FullName) -and $_.Name -like '*__CrateName__*'
} | Sort-Object { $_.FullName.Length } -Descending
foreach ($item in $named) {
    $newName = $item.Name.Replace('__CrateName__', $CrateName)
    Rename-Item -LiteralPath $item.FullName -NewName $newName
    Write-Host "    Renamed $($item.Name) -> $newName" -ForegroundColor DarkGray
}

# 3) Activate Claude Code shared settings if shipped as a .template. The Rust
#    template currently ships an active, hook-only settings.json (no permission
#    grants), so this is a no-op unless a future .template is added.
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

if (-not $KeepScript) {
    Remove-Item -LiteralPath $selfPath -Force
}
