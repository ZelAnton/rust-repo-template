#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-Equal([object]$actual, [object]$expected, [string]$message) {
    if ($actual -cne $expected) {
        throw "$message`nExpected: $expected`nActual:   $actual"
    }
}

function Invoke-CapturedProcess(
    [string]$fileName,
    [string[]]$arguments,
    [string]$workingDirectory
) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $fileName
    $startInfo.WorkingDirectory = $workingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Failed to start $fileName"
    }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()

    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout.GetAwaiter().GetResult()
        Stderr = $stderr.GetAwaiter().GetResult()
    }
}

function Assert-ProcessSucceeded($result, [string]$description) {
    if ($result.ExitCode -ne 0) {
        throw "$description failed with exit code $($result.ExitCode).`nstdout:`n$($result.Stdout)`nstderr:`n$($result.Stderr)"
    }
}

function Copy-Template([string]$source, [string]$destination) {
    [void](New-Item -ItemType Directory -Path $destination)
    foreach ($item in (Get-ChildItem -LiteralPath $source -Force)) {
        if ($item.Name -in @('.git', '.jj', '.work', 'target')) {
            continue
        }
        Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force
    }
}

function Get-TreeFingerprint([string]$root) {
    $entries = Get-ChildItem -LiteralPath $root -File -Recurse -Force |
        Sort-Object FullName |
        ForEach-Object {
            $relative = [IO.Path]::GetRelativePath($root, $_.FullName)
            "$relative=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
        }
    $entries -join "`n"
}

function Get-InitializerInvocation(
    [ValidateSet('powershell', 'posix')][string]$kind,
    [string]$copyRoot,
    [string]$author,
    [string]$authorEmail
) {
    if ($kind -eq 'powershell') {
        return [pscustomobject]@{
            FileName = $script:PwshPath
            Arguments = @(
                '-NoProfile', '-File', (Join-Path $copyRoot 'scripts/init.ps1'),
                '-ProjectName', 'init-security', '-Author', $author,
                '-AuthorEmail', $authorEmail, '-GitHubOwner', 'example',
                '-Description', 'Initializer security regression fixture',
                '-Year', '2026', '-KeepScript'
            )
        }
    }

    [pscustomobject]@{
        FileName = $script:BashPath
        Arguments = @(
            (Join-Path $copyRoot 'scripts/init.sh'),
            '--project-name', 'init-security', '--author', $author,
            '--author-email', $authorEmail, '--github-owner', 'example',
            '--description', 'Initializer security regression fixture',
            '--year', '2026', '--keep-script'
        )
    }
}

function Test-SuccessfulInitialization(
    [ValidateSet('powershell', 'posix')][string]$kind,
    [string]$caseName,
    [string]$author,
    [string]$authorEmail
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-$caseName"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    $invocation = Get-InitializerInvocation $kind $copyRoot $author $authorEmail
    $result = Invoke-CapturedProcess $invocation.FileName $invocation.Arguments $copyRoot
    Assert-ProcessSucceeded $result "$kind initializer ($caseName)"

    $verifyArguments = @(
        $script:VerifierPath, '--repo', $copyRoot, '--bash', $script:BashPath,
        '--expected-name', $author, '--expected-email', $authorEmail
    )
    $verification = Invoke-CapturedProcess $script:PythonPath $verifyArguments $copyRoot
    Assert-ProcessSucceeded $verification "$kind generated workflow verification ($caseName)"

    [IO.File]::ReadAllText((Join-Path $copyRoot '.github/workflows/release.yml'))
}

function Test-RejectedLineBreak(
    [ValidateSet('powershell', 'posix')][string]$kind,
    [ValidateSet('author', 'email')][string]$field
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-reject-$field"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    $before = Get-TreeFingerprint $copyRoot
    $author = if ($field -eq 'author') { "Line`nBreak" } else { 'Valid Name' }
    $authorEmail = if ($field -eq 'email') { "line`rbreak@example.com" } else { 'valid@example.com' }
    $invocation = Get-InitializerInvocation $kind $copyRoot $author $authorEmail
    $result = Invoke-CapturedProcess $invocation.FileName $invocation.Arguments $copyRoot

    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted a line break in $field"
    }
    if (("$($result.Stdout)`n$($result.Stderr)") -notmatch 'single line; CR and LF characters are not supported') {
        throw "$kind initializer returned an unclear diagnostic for a line break in $field.`nstdout:`n$($result.Stdout)`nstderr:`n$($result.Stderr)"
    }
    Assert-Equal (Get-TreeFingerprint $copyRoot) $before "$kind initializer mutated files before rejecting $field"
}

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$VerifierPath = Join-Path $PSScriptRoot 'verify-generated-workflow.py'
$PwshPath = (Get-Command pwsh -ErrorAction Stop).Source

if ($IsWindows) {
    $gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    $BashPath = if (Test-Path -LiteralPath $gitBash) {
        $gitBash
    } else {
        (Get-Command bash -ErrorAction Stop).Source
    }
    $PythonPath = (Get-Command python -ErrorAction Stop).Source
} else {
    $BashPath = (Get-Command bash -ErrorAction Stop).Source
    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $python) {
        $python = Get-Command python -ErrorAction Stop
    }
    $PythonPath = $python.Source
}

$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("rust-template-init-security-" + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $TempRoot)

try {
    $ordinaryAuthor = 'Renée O''Connor, "R&D" + QA'
    $ordinaryEmail = 'anne.o+release@example.com'
    $hostileAuthor = 'Eve "$(touch$IFS./init-security-name-owned)" #:[]{}&*!| suffix'
    $hostileEmail = 'attacker+$(touch$IFS./init-security-email-owned)@example.com'

    $psOrdinary = Test-SuccessfulInitialization powershell ordinary $ordinaryAuthor $ordinaryEmail
    $shOrdinary = Test-SuccessfulInitialization posix ordinary $ordinaryAuthor $ordinaryEmail
    Assert-Equal $shOrdinary $psOrdinary 'Initializers generated different ordinary release workflows'

    $psHostile = Test-SuccessfulInitialization powershell hostile $hostileAuthor $hostileEmail
    $shHostile = Test-SuccessfulInitialization posix hostile $hostileAuthor $hostileEmail
    Assert-Equal $shHostile $psHostile 'Initializers generated different hostile release workflows'

    foreach ($kind in @('powershell', 'posix')) {
        Test-RejectedLineBreak $kind author
        Test-RejectedLineBreak $kind email
    }

    Write-Host 'Initializer release-identity security checks passed.' -ForegroundColor Green
} finally {
    $resolvedTemp = [IO.Path]::GetFullPath($TempRoot)
    $resolvedSystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $safePrefix = $resolvedTemp.StartsWith($resolvedSystemTemp, $comparison)
    $safeName = [IO.Path]::GetFileName($resolvedTemp).StartsWith('rust-template-init-security-', [StringComparison]::Ordinal)
    if (-not $safePrefix -or -not $safeName) {
        throw "Refusing to remove unexpected temporary path: $resolvedTemp"
    }
    if (Test-Path -LiteralPath $resolvedTemp) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
