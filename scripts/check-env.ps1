#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Checks this machine can build and test this Rust crate before you initialize
    the template.

.DESCRIPTION
    Verifies cargo and rustc can each report a usable version. rust-toolchain.toml
    pins the channel and components (rustfmt, clippy), which rustup installs
    automatically on the first build. Prints "Environment ready" and exits 0
    only after both checks succeed; otherwise it reports every failed check and
    exits 1.

    Run it first, before scripts/init.ps1:

        pwsh ./scripts/check-env.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$problems = @()

Write-Host "==> Checking environment for Rust development" -ForegroundColor Cyan

# Required: cargo (build/test driver) and rustc (the compiler). Resolve only
# applications so a same-named shell function cannot stand in for the tool.
foreach ($tool in @('cargo', 'rustc')) {
    $command = Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) {
        $problems += "$tool ('$tool' is not on PATH)"
        continue
    }

    try {
        $versionOutput = ((& $command.Source --version 2>$null) | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    catch {
        $problems += "$tool ('$tool --version' could not be executed)"
        continue
    }

    if ($exitCode -ne 0) {
        $problems += "$tool ('$tool --version' exited with code $exitCode)"
    }
    elseif ([string]::IsNullOrWhiteSpace($versionOutput)) {
        $problems += "$tool ('$tool --version' returned empty output)"
    }
    elseif ($versionOutput -notmatch "^$tool\s+\S+") {
        $problems += "$tool ('$tool --version' returned unusable output)"
    }
    else {
        Write-Host "    $versionOutput" -ForegroundColor DarkGray
    }
}

if ($problems.Count -eq 0) {
    Write-Host ""
    Write-Host "Environment ready. Next: pwsh ./scripts/init.ps1 -ProjectName ..." -ForegroundColor Green
    Write-Host "(rustup installs the pinned stable + rustfmt/clippy on the first cargo build.)" -ForegroundColor DarkGray
    exit 0
}

Write-Host ""
Write-Host "Environment NOT ready. Problems:" -ForegroundColor Red
foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
Write-Host ""
Write-Host "Install the Rust toolchain via rustup, then re-run this check:" -ForegroundColor Yellow
Write-Host "  Windows : winget install Rustlang.Rustup ; rustup default stable"
Write-Host "  macOS   : brew install rustup ; rustup-init"
Write-Host "  Linux   : curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
Write-Host "  (any OS) : see https://rustup.rs"
exit 1
