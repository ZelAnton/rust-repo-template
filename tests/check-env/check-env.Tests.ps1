#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$checkScript = (Resolve-Path (Join-Path $PSScriptRoot '..\..\scripts\check-env.ps1')).Path
$pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source

function Assert-Contains {
    param([string]$Text, [string]$Expected, [string]$Scenario)

    if (-not $Text.Contains($Expected)) {
        throw "$Scenario`: expected output to contain '$Expected'. Actual output:`n$Text"
    }
}

function Write-FakeTool {
    param([string]$Bin, [string]$Tool, [string]$Behavior)

    if ($IsWindows) {
        $path = Join-Path $Bin "$Tool.cmd"
        $body = switch ($Behavior) {
            'success' { "@echo off`r`necho $Tool 1.2.3-fake`r`nexit /b 0`r`n" }
            'failure' { "@echo off`r`nexit /b 23`r`n" }
            'empty' { "@echo off`r`nexit /b 0`r`n" }
            'unusable' { "@echo off`r`necho not-a-version`r`nexit /b 0`r`n" }
        }
        [IO.File]::WriteAllText($path, $body)
        return
    }

    $path = Join-Path $Bin $Tool
    $body = switch ($Behavior) {
        'success' { "#!/bin/sh`nprintf '%s\\n' '$Tool 1.2.3-fake'`n" }
        'failure' { "#!/bin/sh`nexit 23`n" }
        'empty' { "#!/bin/sh`nexit 0`n" }
        'unusable' { "#!/bin/sh`nprintf '%s\\n' 'not-a-version'`n" }
    }
    [IO.File]::WriteAllText($path, $body)
    & chmod +x $path
    if ($LASTEXITCODE -ne 0) { throw "chmod failed for $path" }
}

function Invoke-Scenario {
    param(
        [string]$Name,
        [ValidateSet('missing', 'success', 'failure', 'empty', 'unusable')][string]$Cargo,
        [ValidateSet('missing', 'success', 'failure', 'empty', 'unusable')][string]$Rustc,
        [int]$ExpectedExit,
        [string[]]$ExpectedOutput
    )

    $root = Join-Path ([IO.Path]::GetTempPath()) "check-env-$([guid]::NewGuid())"
    $bin = Join-Path $root 'bin'
    New-Item -ItemType Directory -Path $bin | Out-Null
    try {
        if ($Cargo -ne 'missing') { Write-FakeTool $bin cargo $Cargo }
        if ($Rustc -ne 'missing') { Write-FakeTool $bin rustc $Rustc }

        $savedPath = $env:PATH
        try {
            $env:PATH = $bin
            $output = (& $pwsh -NoLogo -NoProfile -File $checkScript 2>&1 | Out-String)
            $exitCode = $LASTEXITCODE
        }
        finally {
            $env:PATH = $savedPath
        }

        if ($exitCode -ne $ExpectedExit) {
            throw "$Name`: expected exit $ExpectedExit, got $exitCode. Output:`n$output"
        }
        foreach ($expected in $ExpectedOutput) {
            Assert-Contains $output $expected $Name
        }
        if ($ExpectedExit -ne 0 -and $output.Contains('Environment ready.')) {
            throw "$Name`: failure output must not declare the environment ready."
        }
    }
    finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Scenario success success success 0 @(
    'cargo 1.2.3-fake', 'rustc 1.2.3-fake', 'Environment ready.'
)
Invoke-Scenario cargo-missing missing success 1 @(
    "cargo ('cargo' is not on PATH)", 'rustc 1.2.3-fake', 'Environment NOT ready.'
)
Invoke-Scenario rustc-missing success missing 1 @(
    "rustc ('rustc' is not on PATH)", 'cargo 1.2.3-fake', 'Environment NOT ready.'
)
Invoke-Scenario cargo-failure failure success 1 @(
    "cargo ('cargo --version' exited with code 23)", 'rustc 1.2.3-fake'
)
Invoke-Scenario rustc-failure success failure 1 @(
    "rustc ('rustc --version' exited with code 23)", 'cargo 1.2.3-fake'
)
Invoke-Scenario cargo-empty empty success 1 @(
    "cargo ('cargo --version' returned empty output)", 'rustc 1.2.3-fake'
)
Invoke-Scenario rustc-empty success empty 1 @(
    "rustc ('rustc --version' returned empty output)", 'cargo 1.2.3-fake'
)
Invoke-Scenario cargo-unusable unusable success 1 @(
    "cargo ('cargo --version' returned unusable output)", 'rustc 1.2.3-fake'
)
Invoke-Scenario rustc-unusable success unusable 1 @(
    "rustc ('rustc --version' returned unusable output)", 'cargo 1.2.3-fake'
)
Invoke-Scenario both-fail failure failure 1 @(
    "cargo ('cargo --version' exited with code 23)",
    "rustc ('rustc --version' exited with code 23)"
)

Write-Host 'PowerShell check-env scenarios passed.'
