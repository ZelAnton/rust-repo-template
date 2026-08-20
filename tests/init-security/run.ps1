#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-Equal([object]$actual, [object]$expected, [string]$message) {
    if ($actual -cne $expected) {
        throw "$message`nExpected: $expected`nActual:   $actual"
    }
}

function ConvertTo-PlainDiagnostic([AllowEmptyString()][string]$text) {
    # PowerShell may preserve terminal styling and wrap formatted error records
    # even when stderr is redirected. Strip only ANSI CSI transport markup, then
    # undo formatting whitespace so semantic diagnostic checks stay exact.
    $ansiCsi = [regex]::new(([string][char]27) + '\[[0-?]*[ -/]*[@-~]')
    ($ansiCsi.Replace($text, '') -replace '\s+', ' ').Trim()
}

function Assert-DiagnosticContains($result, [string]$expected, [string]$description) {
    $raw = "$($result.Stdout)`n$($result.Stderr)"
    $plain = ConvertTo-PlainDiagnostic $raw
    if ($plain.IndexOf($expected, [StringComparison]::Ordinal) -lt 0) {
        throw "$description`nExpected diagnostic: $expected`nNormalized output:`n$plain`nstdout:`n$($result.Stdout)`nstderr:`n$($result.Stderr)"
    }
}

function Test-DiagnosticNormalization {
    $escape = [char]27
    $decorated = "${escape}[31;1mInvalid value: CR and${escape}[0m`n${escape}[36;1mLF are unsupported.${escape}[0m"
    Assert-Equal `
        (ConvertTo-PlainDiagnostic $decorated) `
        'Invalid value: CR and LF are unsupported.' `
        'ANSI diagnostic normalization did not preserve the semantic message'
}

function Invoke-CapturedProcess(
    [string]$fileName,
    [string[]]$arguments,
    [string]$workingDirectory,
    [Collections.IDictionary]$environment = @{}
) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $fileName
    $startInfo.WorkingDirectory = $workingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($entry in $environment.GetEnumerator()) {
        $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
    }
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
    [switch]$UseDefaultAuthorEmail,
    [bool]$KeepScript = $true
) {
    if ($kind -eq 'powershell') {
        $arguments = @(
            '-NoProfile', '-File', (Join-Path $copyRoot 'scripts/init.ps1'),
            '-ProjectName', 'init-security', '-GitHubOwner', 'example',
            '-Description', 'Initializer security regression fixture',
            '-Year', '2026'
        )
        if ($KeepScript) { $arguments += '-KeepScript' }
        if (-not $UseDefaultAuthor) { $arguments += @('-Author', $author) }
        if (-not $UseDefaultAuthorEmail) { $arguments += @('-AuthorEmail', $authorEmail) }
        return [pscustomobject]@{
            FileName = $script:PwshPath
            Arguments = $arguments
            Environment = @{}
        }
    }

    # MSYS2 reparses the Windows command line before Bash sees argv and can
    # consume leading quote/backslash characters. Carry identity fixtures in
    # the environment, then construct the real initializer argv inside Bash so
    # this harness measures init.sh and Git rather than that Windows shim.
    $command = @'
arguments=("$1" --project-name init-security --github-owner example \
  --description "Initializer security regression fixture" --year 2026)
if [ "$INIT_KEEP_SCRIPT" = "1" ]; then
  arguments+=(--keep-script)
fi
if [ "$INIT_USE_DEFAULT_AUTHOR" != "1" ]; then
  arguments+=(--author "$INIT_AUTHOR")
fi
if [ "$INIT_USE_DEFAULT_AUTHOR_EMAIL" != "1" ]; then
  arguments+=(--author-email "$INIT_AUTHOR_EMAIL")
fi
exec bash "${arguments[@]}"
'@
    [pscustomobject]@{
        FileName = $script:BashPath
        Arguments = @('-c', $command, 'init-security-wrapper', (Join-Path $copyRoot 'scripts/init.sh'))
        Environment = @{
            INIT_AUTHOR = $author
            INIT_AUTHOR_EMAIL = $authorEmail
            INIT_USE_DEFAULT_AUTHOR = if ($UseDefaultAuthor) { '1' } else { '0' }
            INIT_USE_DEFAULT_AUTHOR_EMAIL = if ($UseDefaultAuthorEmail) { '1' } else { '0' }
            INIT_KEEP_SCRIPT = if ($KeepScript) { '1' } else { '0' }
        }
    }
}

function Assert-TemplateOnlySecurityArtifactsRemoved([string]$copyRoot, [string]$description) {
    foreach ($relativePath in @(
        'tests/init-security',
        'tests/init-security/run.ps1',
        'tests/init-security/verify-generated-workflow.py'
    )) {
        if (Test-Path -LiteralPath (Join-Path $copyRoot $relativePath)) {
            throw "$description retained template-only path $relativePath"
        }
    }

    $ciPath = Join-Path $copyRoot '.github/workflows/ci.yml'
    $ciText = [IO.File]::ReadAllText($ciPath)
    if ($ciText.Contains('template-only-init-security') -or $ciText.Contains('tests/init-security')) {
        throw "$description retained the template-only security CI entrypoint"
    }
    $yamlCheck = Invoke-CapturedProcess $script:PythonPath @(
        '-c', 'import pathlib, sys, yaml; yaml.safe_load(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))',
        $ciPath
    ) $copyRoot
    Assert-ProcessSucceeded $yamlCheck "$description generated CI YAML parse"
}

function Add-HiddenInitializerFixture([string]$copyRoot) {
    $fixtureRoot = Join-Path $copyRoot '.initializer-hidden-fixture'
    $fixtureDirectory = New-Item -ItemType Directory -Path $fixtureRoot
    if ($IsWindows) {
        $fixtureDirectory.Attributes = $fixtureDirectory.Attributes -bor [IO.FileAttributes]::Hidden
    }
    [IO.File]::WriteAllText(
        (Join-Path $fixtureRoot '__ProjectName__-fixture.txt'),
        '__Description__',
        (New-Object Text.UTF8Encoding($false))
    )
}

function Assert-HiddenInitializerFixtureUpdated([string]$copyRoot, [string]$description) {
    $fixturePath = Join-Path $copyRoot '.initializer-hidden-fixture/init-security-fixture.txt'
    if (-not (Test-Path -LiteralPath $fixturePath)) {
        throw "$description did not rename a tokenized file inside a hidden directory"
    }
    Assert-Equal `
        ([IO.File]::ReadAllText($fixturePath)) `
        'Initializer security regression fixture' `
        "$description did not replace content inside a hidden directory"
}

function Test-SuccessfulInitialization(
    [ValidateSet('powershell', 'posix')][string]$kind,
    [ValidateSet('explicit', 'git-config')][string]$source,
    [string]$caseName,
    [string]$author,
    [string]$authorEmail,
    [bool]$KeepScript = $true
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-$source-$caseName"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    Add-HiddenInitializerFixture $copyRoot
    $useDefaults = $source -eq 'git-config'
    if ($useDefaults) {
        $init = Invoke-CapturedProcess 'git' @('init', '-q') $copyRoot
        Assert-ProcessSucceeded $init "git init for $kind $source $caseName"
        foreach ($entry in @(
            @('user.name', $author),
            @('user.email', $authorEmail)
        )) {
            $configured = Invoke-CapturedProcess 'git' @('config', '--local', $entry[0], $entry[1]) $copyRoot
            Assert-ProcessSucceeded $configured "git config for $kind $source $caseName"
            $raw = Invoke-CapturedProcess 'git' @('config', '--null', '--get', $entry[0]) $copyRoot
            Assert-ProcessSucceeded $raw "read-back git config for $kind $source $caseName"
            Assert-Equal $raw.Stdout ($entry[1] + "`0") "git config changed $($entry[0]) for $kind $source $caseName"
        }
    }
    $invocation = Get-InitializerInvocation $kind $copyRoot $author $authorEmail `
        -UseDefaultAuthor:$useDefaults -UseDefaultAuthorEmail:$useDefaults -KeepScript:$KeepScript
    $result = Invoke-CapturedProcess $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment
    Assert-ProcessSucceeded $result "$kind initializer ($source $caseName)"
    Assert-TemplateOnlySecurityArtifactsRemoved $copyRoot "$kind initializer ($source $caseName)"
    Assert-HiddenInitializerFixtureUpdated $copyRoot "$kind initializer ($source $caseName)"

    foreach ($initializer in @('scripts/init.ps1', 'scripts/init.sh')) {
        $exists = Test-Path -LiteralPath (Join-Path $copyRoot $initializer)
        if ($exists -ne $KeepScript) {
            throw "$kind initializer ($source $caseName) produced an unexpected keep-script result for $initializer"
        }
    }

    if (-not $KeepScript) {
        foreach ($check in @(
            @{ FileName = 'yamllint'; Arguments = @('.'); Description = 'downstream YAML lint' },
            @{ FileName = 'cargo'; Arguments = @('fmt', '--all', '--', '--check'); Description = 'downstream rustfmt' },
            @{ FileName = 'cargo'; Arguments = @('check', '--all-targets'); Description = 'downstream cargo check' }
        )) {
            $checkResult = Invoke-CapturedProcess $check.FileName $check.Arguments $copyRoot
            Assert-ProcessSucceeded $checkResult "$kind initializer ($source $caseName) $($check.Description)"
        }
    }

    $verifyArguments = @(
        $script:VerifierPath, '--repo', $copyRoot, '--bash', $script:BashPath,
        '--expected-name', $author, '--expected-email', $authorEmail
    )
    $verification = Invoke-CapturedProcess $script:PythonPath $verifyArguments $copyRoot
    Assert-ProcessSucceeded $verification "$kind generated workflow verification ($source $caseName)"

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
    $result = Invoke-CapturedProcess $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment

    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted a line break in $field"
    }
    Assert-DiagnosticContains $result `
        'single line; CR and LF characters are not supported' `
        "$kind initializer returned an unclear diagnostic for a line break in $field."
    Assert-Equal (Get-TreeFingerprint $copyRoot) $before "$kind initializer mutated files before rejecting $field"
}

function Test-RejectedGitIdentValue(
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
    $result = Invoke-CapturedProcess $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment

    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted $caseName in $source $field"
    }
    Assert-DiagnosticContains $result `
        'not preserved exactly when Git formats a commit identity' `
        "$kind initializer returned an unclear diagnostic for $caseName in $source $field."
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
    $result = Invoke-CapturedProcess $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment

    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted $caseName in default git-config $field"
    }
    Assert-DiagnosticContains $result `
        'single line; CR and LF characters are not supported' `
        "$kind initializer returned an unclear diagnostic for $caseName in default git-config $field."
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
    Test-DiagnosticNormalization

    $ordinaryAuthor = 'Renée  O''Connor, "R&D" + QA'
    $ordinaryEmail = 'anne.o+release@example.com'
    $hostileAuthor = 'Eve "$(touch$IFS./init-security-name-owned)" #:[]{}&*!| suffix'
    $hostileEmail = 'attacker+$(touch$IFS./init-security-email-owned)@example.com'

    $psOrdinary = Test-SuccessfulInitialization powershell explicit ordinary $ordinaryAuthor $ordinaryEmail
    $shOrdinary = Test-SuccessfulInitialization posix explicit ordinary $ordinaryAuthor $ordinaryEmail
    Assert-Equal $shOrdinary $psOrdinary 'Initializers generated different ordinary release workflows'

    $psStandard = Test-SuccessfulInitialization powershell explicit standard-no-keep $ordinaryAuthor $ordinaryEmail -KeepScript:$false
    $shStandard = Test-SuccessfulInitialization posix explicit standard-no-keep $ordinaryAuthor $ordinaryEmail -KeepScript:$false
    Assert-Equal $shStandard $psStandard 'Standard initializers generated different release workflows'

    $psHostile = Test-SuccessfulInitialization powershell explicit hostile $hostileAuthor $hostileEmail
    $shHostile = Test-SuccessfulInitialization posix explicit hostile $hostileAuthor $hostileEmail
    Assert-Equal $shHostile $psHostile 'Initializers generated different hostile release workflows'

    # Git preserves this punctuation internally and permits '.' at either edge.
    # Exercise the actual release commit for both initializer and input channels
    # so the lossless guard does not grow into an over-broad punctuation ban.
    $roundTripAuthor = '.Edge "double" ''single'', colon: semicolon; backslash\ exact.'
    $roundTripEmail = '.edge"double"''single'',colon:semicolon;backslash\exact.@example.com.'
    $roundTripWorkflow = $null
    foreach ($source in @('explicit', 'git-config')) {
        $psRoundTrip = Test-SuccessfulInitialization powershell $source allowed-punctuation $roundTripAuthor $roundTripEmail
        $shRoundTrip = Test-SuccessfulInitialization posix $source allowed-punctuation $roundTripAuthor $roundTripEmail
        Assert-Equal $shRoundTrip $psRoundTrip "Initializers generated different allowed-punctuation workflows for $source input"
        if ($null -eq $roundTripWorkflow) {
            $roundTripWorkflow = $psRoundTrip
        } else {
            Assert-Equal $psRoundTrip $roundTripWorkflow 'Explicit and git-config inputs generated different allowed-punctuation workflows'
        }
    }

    foreach ($kind in @('powershell', 'posix')) {
        Test-RejectedLineBreak $kind author
        Test-RejectedLineBreak $kind email
        foreach ($field in @('author', 'email')) {
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
                    @{ Name = 'internal-open-angle'; Value = 'Angle<Edge' },
                    @{ Name = 'internal-close-angle'; Value = 'Angle>Edge' },
                    @{ Name = 'leading-space'; Value = ' Edge' },
                    @{ Name = 'trailing-space'; Value = 'Edge ' },
                    @{ Name = 'leading-tab'; Value = "`tEdge" },
                    @{ Name = 'trailing-tab'; Value = "Edge`t" },
                    @{ Name = 'leading-vertical-tab'; Value = "`vEdge" },
                    @{ Name = 'trailing-vertical-tab'; Value = "Edge`v" },
                    @{ Name = 'leading-form-feed'; Value = "`fEdge" },
                    @{ Name = 'trailing-form-feed'; Value = "Edge`f" },
                    @{ Name = 'leading-double-quote'; Value = '"Edge' },
                    @{ Name = 'trailing-double-quote'; Value = 'Edge"' },
                    @{ Name = 'leading-single-quote'; Value = "'Edge" },
                    @{ Name = 'trailing-single-quote'; Value = "Edge'" },
                    @{ Name = 'leading-comma'; Value = ',Edge' },
                    @{ Name = 'trailing-comma'; Value = 'Edge,' },
                    @{ Name = 'leading-colon'; Value = ':Edge' },
                    @{ Name = 'trailing-colon'; Value = 'Edge:' },
                    @{ Name = 'leading-semicolon'; Value = ';Edge' },
                    @{ Name = 'trailing-semicolon'; Value = 'Edge;' },
                    @{ Name = 'leading-backslash'; Value = '\Edge' },
                    @{ Name = 'trailing-backslash'; Value = 'Edge\' }
                )) {
                    Test-RejectedGitIdentValue $kind $field $source $case.Name $case.Value
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
