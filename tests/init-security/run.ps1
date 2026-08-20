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
        Where-Object {
            $relative = [IO.Path]::GetRelativePath($root, $_.FullName)
            $relative -notmatch '(^|[\\/])\.(git|jj)([\\/]|$)'
        } |
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
    [string]$authorEmail,
    [switch]$UseDefaultAuthor,
    [switch]$UseDefaultAuthorEmail
) {
    if ($kind -eq 'powershell') {
        $arguments = @(
            '-NoProfile', '-File', (Join-Path $copyRoot 'scripts/init.ps1'),
            '-ProjectName', 'init-security', '-GitHubOwner', 'example',
            '-Description', 'Initializer security regression fixture',
            '-Year', '2026', '-KeepScript'
        )
        if (-not $UseDefaultAuthor) { $arguments += @('-Author', $author) }
        if (-not $UseDefaultAuthorEmail) { $arguments += @('-AuthorEmail', $authorEmail) }
        return [pscustomobject]@{
            FileName = $script:PwshPath
            Arguments = $arguments
        }
    }

    $arguments = @(
        (Join-Path $copyRoot 'scripts/init.sh'),
        '--project-name', 'init-security', '--github-owner', 'example',
        '--description', 'Initializer security regression fixture',
        '--year', '2026', '--keep-script'
    )
    if (-not $UseDefaultAuthor) { $arguments += @('--author', $author) }
    if (-not $UseDefaultAuthorEmail) { $arguments += @('--author-email', $authorEmail) }
    [pscustomobject]@{
        FileName = $script:BashPath
        Arguments = $arguments
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

function Test-RejectedAngleBracket(
    [ValidateSet('powershell', 'posix')][string]$kind,
    [ValidateSet('author', 'email')][string]$field,
    [ValidateSet('<', '>')][string]$character
) {
    $label = if ($character -eq '<') { 'open' } else { 'close' }
    $copyRoot = Join-Path $script:TempRoot "$kind-reject-$field-angle-$label"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    $before = Get-TreeFingerprint $copyRoot
    $author = if ($field -eq 'author') { "Angle ${character}Name" } else { 'Valid Name' }
    $authorEmail = if ($field -eq 'email') { "angle${character}mail@example.com" } else { 'valid@example.com' }
    $invocation = Get-InitializerInvocation $kind $copyRoot $author $authorEmail
    $result = Invoke-CapturedProcess $invocation.FileName $invocation.Arguments $copyRoot

    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted '$character' in $field"
    }
    if (("$($result.Stdout)`n$($result.Stderr)") -notmatch "must not contain '<' or '>' because Git strips those characters") {
        throw "$kind initializer returned an unclear diagnostic for '$character' in $field.`nstdout:`n$($result.Stdout)`nstderr:`n$($result.Stderr)"
    }
    Assert-Equal (Get-TreeFingerprint $copyRoot) $before "$kind initializer mutated files before rejecting '$character' in $field"
}

function Test-RejectedEdgeWhitespace(
    [ValidateSet('powershell', 'posix')][string]$kind,
    [ValidateSet('author', 'email')][string]$field,
    [ValidateSet('explicit', 'git-config')][string]$source,
    [string]$caseName,
    [string]$value
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-reject-$source-$field-$caseName"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    $author = if ($field -eq 'author') { $value } else { 'Valid  Name, QA' }
    $authorEmail = if ($field -eq 'email') { $value } else { 'valid.release+qa@example.com' }
    $useDefaultAuthor = $false
    $useDefaultEmail = $false

    if ($source -eq 'git-config') {
        $init = Invoke-CapturedProcess 'git' @('init', '-q') $copyRoot
        Assert-ProcessSucceeded $init "git init for $kind $source $field $caseName"
        $key = if ($field -eq 'author') { 'user.name' } else { 'user.email' }
        $configured = Invoke-CapturedProcess 'git' @('config', '--local', $key, $value) $copyRoot
        Assert-ProcessSucceeded $configured "git config for $kind $source $field $caseName"
        $raw = Invoke-CapturedProcess 'git' @('config', '--null', '--get', $key) $copyRoot
        Assert-ProcessSucceeded $raw "read-back git config for $kind $source $field $caseName"
        Assert-Equal $raw.Stdout ($value + "`0") "git did not preserve the $caseName fixture exactly"
        $useDefaultAuthor = $field -eq 'author'
        $useDefaultEmail = $field -eq 'email'
    }

    $before = Get-TreeFingerprint $copyRoot
    $invocation = Get-InitializerInvocation $kind $copyRoot $author $authorEmail `
        -UseDefaultAuthor:$useDefaultAuthor -UseDefaultAuthorEmail:$useDefaultEmail
    $result = Invoke-CapturedProcess $invocation.FileName $invocation.Arguments $copyRoot

    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted $caseName in $source $field"
    }
    if (("$($result.Stdout)`n$($result.Stderr)") -notmatch 'must not start or end with ASCII whitespace because Git strips it') {
        throw "$kind initializer returned an unclear diagnostic for $caseName in $source $field.`nstdout:`n$($result.Stdout)`nstderr:`n$($result.Stderr)"
    }
    Assert-Equal (Get-TreeFingerprint $copyRoot) $before "$kind initializer mutated files before rejecting $caseName in $source $field"
}

function Test-RejectedGitConfigLineBreak(
    [ValidateSet('powershell', 'posix')][string]$kind,
    [ValidateSet('author', 'email')][string]$field,
    [string]$caseName,
    [string]$value
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-reject-config-$field-$caseName"
    Copy-Template -source $script:RepoRoot -destination $copyRoot

    $init = Invoke-CapturedProcess 'git' @('init', '-q') $copyRoot
    Assert-ProcessSucceeded $init "git init for $kind default-config $field $caseName"
    foreach ($entry in @(
        @('user.name', 'Valid Name'),
        @('user.email', 'valid@example.com')
    )) {
        $configured = Invoke-CapturedProcess 'git' @('config', '--local', $entry[0], $entry[1]) $copyRoot
        Assert-ProcessSucceeded $configured "baseline git config for $kind default-config $field $caseName"
    }
    $key = if ($field -eq 'author') { 'user.name' } else { 'user.email' }
    $configured = Invoke-CapturedProcess 'git' @('config', '--local', $key, $value) $copyRoot
    Assert-ProcessSucceeded $configured "multiline git config for $kind default-config $field $caseName"
    $raw = Invoke-CapturedProcess 'git' @('config', '--null', '--get', $key) $copyRoot
    Assert-ProcessSucceeded $raw "read-back git config for $kind default-config $field $caseName"
    Assert-Equal $raw.Stdout ($value + "`0") "git did not preserve the $caseName fixture exactly"

    $before = Get-TreeFingerprint $copyRoot
    $useDefaultAuthor = $field -eq 'author'
    $useDefaultEmail = $field -eq 'email'
    $invocation = Get-InitializerInvocation $kind $copyRoot 'Valid Name' 'valid@example.com' `
        -UseDefaultAuthor:$useDefaultAuthor -UseDefaultAuthorEmail:$useDefaultEmail
    $result = Invoke-CapturedProcess $invocation.FileName $invocation.Arguments $copyRoot

    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted $caseName in default git-config $field"
    }
    if (("$($result.Stdout)`n$($result.Stderr)") -notmatch 'single line; CR and LF characters are not supported') {
        throw "$kind initializer returned an unclear diagnostic for $caseName in default git-config $field.`nstdout:`n$($result.Stdout)`nstderr:`n$($result.Stderr)"
    }
    Assert-Equal (Get-TreeFingerprint $copyRoot) $before "$kind initializer mutated files before rejecting $caseName in default git-config $field"
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
    $ordinaryAuthor = 'Renée  O''Connor, "R&D" + QA'
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
        foreach ($field in @('author', 'email')) {
            foreach ($character in @('<', '>')) {
                Test-RejectedAngleBracket $kind $field $character
            }
            foreach ($case in @(
                @{ Name = 'internal-lf'; Value = "Line`nBreak" },
                @{ Name = 'internal-cr'; Value = "Line`rBreak" },
                @{ Name = 'trailing-lf'; Value = "LineBreak`n" },
                @{ Name = 'trailing-cr'; Value = "LineBreak`r" }
            )) {
                Test-RejectedGitConfigLineBreak $kind $field $case.Name $case.Value
            }
            foreach ($source in @('explicit', 'git-config')) {
                foreach ($case in @(
                    @{ Name = 'leading-space'; Value = ' Edge' },
                    @{ Name = 'trailing-space'; Value = 'Edge ' },
                    @{ Name = 'leading-tab'; Value = "`tEdge" },
                    @{ Name = 'trailing-tab'; Value = "Edge`t" },
                    @{ Name = 'leading-vertical-tab'; Value = "`vEdge" },
                    @{ Name = 'trailing-vertical-tab'; Value = "Edge`v" },
                    @{ Name = 'leading-form-feed'; Value = "`fEdge" },
                    @{ Name = 'trailing-form-feed'; Value = "Edge`f" }
                )) {
                    Test-RejectedEdgeWhitespace $kind $field $source $case.Name $case.Value
                }
            }
        }
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
