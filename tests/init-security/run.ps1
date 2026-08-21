#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [switch]$CollisionOnly,
    [switch]$RaceOnly,
    [switch]$ReopenedOnly
)

$ErrorActionPreference = 'Stop'

function Assert-Equal([object]$actual, [object]$expected, [string]$message) {
    if ($actual -cne $expected) {
        throw "$message`nExpected: $expected`nActual:   $actual"
    }
}

function ConvertTo-PlainDiagnostic([AllowEmptyString()][string]$text) {
    # PowerShell may preserve terminal styling and wrap formatted error records
    # even when stderr is redirected. Strip only ANSI CSI transport markup and
    # the known error-record gutter, then undo formatting whitespace so semantic
    # diagnostic checks stay exact.
    $ansiCsi = [regex]::new(([string][char]27) + '\[[0-?]*[ -/]*[@-~]')
    $inErrorRecordGutter = $false
    $semanticLines = foreach ($line in ($ansiCsi.Replace($text, '') -split "\r?\n")) {
        if ($line -match '^\s*Line\s+\|\s*$') {
            $inErrorRecordGutter = $true
            continue
        }
        if ($inErrorRecordGutter) {
            if ($line -match '^\s*\d+\s+\|' -or $line -match '^\s*\|\s*~+\s*$') {
                continue
            }
            if ($line -match '^\s*\|\s?(.*)$') {
                $Matches[1]
                continue
            }
            $inErrorRecordGutter = $false
        }
        $line
    }
    (($semanticLines -join ' ') -replace '\s+', ' ').Trim()
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

    $wrappedErrorRecord = @(
        "${escape}[31;1mException: ${escape}[0m/tmp/example/scripts/init.ps1:135${escape}[0m"
        "${escape}[31;1m${escape}[0m${escape}[36;1mLine |${escape}[0m"
        "${escape}[31;1m${escape}[0m${escape}[36;1m${escape}[36;1m 135 | ${escape}[0m throw `"Invalid -Author: release identity values must be a single …${escape}[0m"
        "${escape}[31;1m${escape}[0m${escape}[36;1m${escape}[36;1m${escape}[0m${escape}[36;1m     | ${escape}[31;1m         ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${escape}[0m"
        "${escape}[31;1m${escape}[0m${escape}[36;1m${escape}[36;1m${escape}[0m${escape}[36;1m${escape}[31;1m${escape}[31;1m${escape}[36;1m     | ${escape}[31;1mInvalid -Author: release identity values must be a single line; CR and${escape}[0m"
        "${escape}[31;1m${escape}[0m${escape}[36;1m${escape}[36;1m${escape}[0m${escape}[36;1m${escape}[31;1m${escape}[31;1m${escape}[36;1m${escape}[31;1m${escape}[36;1m     | ${escape}[31;1mLF characters are not supported.${escape}[0m"
    ) -join "`n"
    Assert-Equal `
        (ConvertTo-PlainDiagnostic $wrappedErrorRecord) `
        'Exception: /tmp/example/scripts/init.ps1:135 Invalid -Author: release identity values must be a single line; CR and LF characters are not supported.' `
        'PowerShell error-record gutter normalization did not preserve the semantic message'
    Assert-Equal `
        (ConvertTo-PlainDiagnostic '135 | ordinary diagnostic output') `
        '135 | ordinary diagnostic output' `
        'Diagnostic normalization removed a pipe outside a PowerShell error-record gutter'
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

function Invoke-CapturedProcessAtCheckpoint(
    [string]$fileName,
    [string[]]$arguments,
    [string]$workingDirectory,
    [Collections.IDictionary]$environment,
    [string]$checkpoint,
    [scriptblock]$onCheckpoint
) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $fileName
    $startInfo.WorkingDirectory = $workingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $checkpointId = [guid]::NewGuid().ToString('N')
    $readyFile = Join-Path $script:TempRoot "checkpoint-$checkpointId.ready"
    $releaseFile = Join-Path $script:TempRoot "checkpoint-$checkpointId.release"
    $environment['INIT_SECURITY_TEST_READY_FILE'] = $readyFile
    $environment['INIT_SECURITY_TEST_RELEASE_FILE'] = $releaseFile
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
    $checkpointDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $readyFile) -and -not $process.HasExited) {
        if ([DateTime]::UtcNow -ge $checkpointDeadline) {
            $process.Kill($true)
            throw "Timed out waiting for initializer checkpoint $checkpoint"
        }
        Start-Sleep -Milliseconds 20
    }
    $observed = Test-Path -LiteralPath $readyFile
    if ($observed) {
        & $onCheckpoint
        [IO.File]::WriteAllText($releaseFile, 'continue')
    }
    $process.WaitForExit()
    $capturedStdout = $stdout.GetAwaiter().GetResult()
    $capturedStderr = $stderr.GetAwaiter().GetResult()
    Remove-Item -LiteralPath $readyFile, $releaseFile -Force -ErrorAction SilentlyContinue

    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $capturedStdout
        Stderr = $capturedStderr
        CheckpointObserved = $observed -and $capturedStdout.Contains($checkpoint)
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
    $entries = Get-ChildItem -LiteralPath $root -Recurse -Force |
        Where-Object {
            $relative = [IO.Path]::GetRelativePath($root, $_.FullName)
            $relative -notmatch '(^|[\\/])\.(git|jj)([\\/]|$)'
        } |
        Sort-Object FullName |
        ForEach-Object {
            $relative = [IO.Path]::GetRelativePath($root, $_.FullName)
            if ($_.LinkType) {
                "link:$relative=$($_.Target -join ',')"
            } elseif ($_.PSIsContainer) {
                "directory:$relative"
            } else {
                "file:$relative=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
            }
        }
    $entries -join "`n"
}

function Add-TextFixture([string]$root, [string]$relativePath, [string]$content) {
    $path = Join-Path $root $relativePath
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [IO.File]::WriteAllText($path, $content, (New-Object Text.UTF8Encoding($false)))
}

function Add-DirectoryFixture([string]$root, [string]$relativePath, [string]$marker) {
    $path = Join-Path $root $relativePath
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [void](New-Item -ItemType Directory -Path $path)
    Add-TextFixture $path 'marker.txt' $marker
}

function Get-InitializerInvocation(
    [ValidateSet('powershell', 'posix')][string]$kind,
    [string]$copyRoot,
    [string]$author,
    [string]$authorEmail,
    [switch]$UseDefaultAuthor,
    [switch]$UseDefaultAuthorEmail,
    [bool]$KeepScript = $true,
    [string]$ProjectName = 'init-security'
) {
    if ($kind -eq 'powershell') {
        $arguments = @(
            '-NoProfile', '-File', (Join-Path $copyRoot 'scripts/init.ps1'),
            '-ProjectName', $ProjectName, '-GitHubOwner', 'example',
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
arguments=("$1" --project-name "$INIT_PROJECT_NAME" --github-owner example \
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
            INIT_PROJECT_NAME = $ProjectName
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

function Add-NestedRenameFixture([string]$copyRoot) {
    Add-TextFixture `
        $copyRoot `
        '.initializer-rename-fixture/__ProjectName__-parent/__ProjectName__-child.txt' `
        '__Description__'
}

function Assert-NestedRenameFixtureUpdated([string]$copyRoot, [string]$description) {
    $renamedPath = Join-Path $copyRoot `
        '.initializer-rename-fixture/init-security-parent/init-security-child.txt'
    if (-not (Test-Path -LiteralPath $renamedPath -PathType Leaf)) {
        throw "$description did not execute nested token-path renames one-to-one"
    }
    Assert-Equal `
        ([IO.File]::ReadAllText($renamedPath)) `
        'Initializer security regression fixture' `
        "$description did not update content before nested token-path renames"
    foreach ($stalePath in @(
        '.initializer-rename-fixture/__ProjectName__-parent',
        '.initializer-rename-fixture/init-security-parent/__ProjectName__-child.txt'
    )) {
        if (Test-Path -LiteralPath (Join-Path $copyRoot $stalePath)) {
            throw "$description retained stale nested token path $stalePath"
        }
    }
}

function Test-SuccessfulInitialization(
    [ValidateSet('powershell', 'posix')][string]$kind,
    [ValidateSet('explicit', 'git-config')][string]$source,
    [string]$caseName,
    [string]$author,
    [string]$authorEmail,
    [bool]$KeepScript = $true,
    [bool]$AddRenameFixtures = $true
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-$source-$caseName"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    if ($AddRenameFixtures) {
        Add-HiddenInitializerFixture $copyRoot
        Add-NestedRenameFixture $copyRoot
    }
    $settingsTemplate = Join-Path $copyRoot '.claude/settings.json.template'
    $expectedSettingsHash = (Get-FileHash -LiteralPath $settingsTemplate -Algorithm SHA256).Hash
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
    if ($AddRenameFixtures) {
        Assert-HiddenInitializerFixtureUpdated $copyRoot "$kind initializer ($source $caseName)"
        Assert-NestedRenameFixtureUpdated $copyRoot "$kind initializer ($source $caseName)"
    }
    $settingsPath = Join-Path $copyRoot '.claude/settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        throw "$kind initializer ($source $caseName) did not activate .claude/settings.json"
    }
    if (Test-Path -LiteralPath $settingsTemplate) {
        throw "$kind initializer ($source $caseName) retained .claude/settings.json.template"
    }
    Assert-Equal `
        ((Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash) `
        $expectedSettingsHash `
        "$kind initializer ($source $caseName) changed shared settings during activation"

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

function Test-CollisionFailure(
    [ValidateSet('powershell', 'posix')][string]$kind,
    [string]$caseName,
    [scriptblock]$arrange,
    [string[]]$expectedDiagnostics
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-collision-$caseName"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    & $arrange $copyRoot
    $before = Get-TreeFingerprint $copyRoot
    $invocation = Get-InitializerInvocation `
        $kind $copyRoot 'Collision Tester' 'collision@example.com'
    $result = Invoke-CapturedProcess `
        $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment

    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted the $caseName collision fixture"
    }
    Assert-DiagnosticContains $result `
        'initialization collision preflight failed; no files were changed' `
        "$kind initializer returned an unclear preflight diagnostic for $caseName."
    foreach ($expected in $expectedDiagnostics) {
        Assert-DiagnosticContains $result $expected `
            "$kind initializer omitted a source-to-destination collision for $caseName."
    }
    Assert-Equal `
        (Get-TreeFingerprint $copyRoot) `
        $before `
        "$kind initializer changed file bytes or tree structure after rejecting $caseName"
}

function Test-CollisionMatrix([ValidateSet('powershell', 'posix')][string]$kind) {
    Test-CollisionFailure $kind 'file-to-file' {
        param($root)
        Add-TextFixture $root '.initializer-collisions/file-__ProjectName__.txt' 'source __Description__'
        Add-TextFixture $root '.initializer-collisions/file-init-security.txt' 'destination must survive'
    } @(
        "destination '.initializer-collisions/file-init-security.txt' already exists (source '.initializer-collisions/file-__ProjectName__.txt')"
    )

    Test-CollisionFailure $kind 'directory-to-directory' {
        param($root)
        Add-DirectoryFixture $root '.initializer-collisions/directory-__ProjectName__' 'source directory'
        Add-DirectoryFixture $root '.initializer-collisions/directory-init-security' 'destination directory'
    } @(
        "destination '.initializer-collisions/directory-init-security' already exists (source '.initializer-collisions/directory-__ProjectName__')"
    )

    Test-CollisionFailure $kind 'file-to-directory' {
        param($root)
        Add-TextFixture $root '.initializer-collisions/mixed-__ProjectName__' 'source file'
        Add-DirectoryFixture $root '.initializer-collisions/mixed-init-security' 'destination directory'
    } @(
        "destination '.initializer-collisions/mixed-init-security' already exists (source '.initializer-collisions/mixed-__ProjectName__')"
    )

    Test-CollisionFailure $kind 'directory-to-file' {
        param($root)
        Add-DirectoryFixture $root '.initializer-collisions/mixed-__ProjectName__' 'source directory'
        Add-TextFixture $root '.initializer-collisions/mixed-init-security' 'destination file'
    } @(
        "destination '.initializer-collisions/mixed-init-security' already exists (source '.initializer-collisions/mixed-__ProjectName__')"
    )

    Test-CollisionFailure $kind 'settings' {
        param($root)
        Add-TextFixture $root '.claude/settings.json' 'existing settings must survive'
    } @(
        "destination '.claude/settings.json' already exists (source '.claude/settings.json.template')"
    )

    Test-CollisionFailure $kind 'multiple' {
        param($root)
        Add-TextFixture $root '.initializer-collisions/first-__ProjectName__.txt' 'first source __Description__'
        Add-TextFixture $root '.initializer-collisions/first-init-security.txt' 'first destination'
        Add-DirectoryFixture $root '.initializer-collisions/second-__ProjectName__' 'second source'
        Add-DirectoryFixture $root '.initializer-collisions/second-init-security' 'second destination'
        Add-TextFixture $root '.claude/settings.json' 'existing settings'
    } @(
        "destination '.initializer-collisions/first-init-security.txt' already exists (source '.initializer-collisions/first-__ProjectName__.txt')",
        "destination '.initializer-collisions/second-init-security' already exists (source '.initializer-collisions/second-__ProjectName__')",
        "destination '.claude/settings.json' already exists (source '.claude/settings.json.template')"
    )

    Test-CollisionFailure $kind 'duplicate-planned-destination' {
        param($root)
        Add-TextFixture $root '.initializer-collisions/__ProjectName__init-security.txt' 'first planned source'
        Add-TextFixture $root '.initializer-collisions/init-security__ProjectName__.txt' 'second planned source'
    } @(
        "destination '.initializer-collisions/init-securityinit-security.txt' is planned by multiple sources: '.initializer-collisions/__ProjectName__init-security.txt', '.initializer-collisions/init-security__ProjectName__.txt'"
    )
}

function Test-CheckedPosixTraversal([ValidateSet('content', 'rename')][string]$phase) {
    $copyRoot = Join-Path $script:TempRoot "posix-traversal-$phase"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    $before = Get-TreeFingerprint $copyRoot
    $invocation = Get-InitializerInvocation `
        posix $copyRoot 'Traversal Tester' 'traversal@example.com'
    $invocation.Environment['INIT_SECURITY_TEST_FAIL_TRAVERSAL'] = $phase
    $result = Invoke-CapturedProcess `
        $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment

    if ($result.ExitCode -eq 0) {
        throw "POSIX initializer accepted a partial $phase traversal"
    }
    Assert-DiagnosticContains $result `
        "could not traverse the complete repository $phase tree; no files were changed" `
        "POSIX initializer returned an unclear diagnostic for a failed $phase traversal."
    Assert-Equal `
        (Get-TreeFingerprint $copyRoot) `
        $before `
        "POSIX initializer mutated the tree after a failed $phase traversal"
}

function Test-CaseInsensitiveFileSystem([string]$root) {
    $leaf = ".harness-case-probe-$([guid]::NewGuid().ToString('N')).tmp"
    $probe = Join-Path $root $leaf.ToLowerInvariant()
    $alias = Join-Path $root $leaf.ToUpperInvariant()
    try {
        [IO.File]::WriteAllText($probe, 'probe', (New-Object Text.UTF8Encoding($false)))
        return Test-Path -LiteralPath $alias
    } finally {
        if (Test-Path -LiteralPath $probe) {
            Remove-Item -LiteralPath $probe -Force
        }
    }
}

function Test-FileSystemAliases(
    [string]$root,
    [string]$firstLeaf,
    [string]$secondLeaf
) {
    $first = Join-Path $root $firstLeaf
    $second = Join-Path $root $secondLeaf
    try {
        $stream = [IO.File]::Open(
            $first,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $stream.Dispose()
        return Test-Path -LiteralPath $second
    } finally {
        if (Test-Path -LiteralPath $first) {
            Remove-Item -LiteralPath $first -Force
        }
    }
}

function Test-CaseAliasDestinations(
    [ValidateSet('powershell', 'posix')][string]$kind
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-case-alias"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    Add-TextFixture $copyRoot '.initializer-case-alias/__ProjectName__A.txt' 'upper target'
    Add-TextFixture $copyRoot '.initializer-case-alias/a__ProjectName__.txt' 'lower target'
    $caseInsensitive = Test-CaseInsensitiveFileSystem $copyRoot
    $before = Get-TreeFingerprint $copyRoot
    $invocation = Get-InitializerInvocation `
        -kind $kind `
        -copyRoot $copyRoot `
        -author 'Case Tester' `
        -authorEmail 'case@example.com' `
        -ProjectName 'a'
    $result = Invoke-CapturedProcess `
        $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment

    if ($caseInsensitive) {
        if ($result.ExitCode -eq 0) {
            throw "$kind initializer accepted case-alias destinations on a case-insensitive filesystem"
        }
        Assert-DiagnosticContains $result `
            'is planned by multiple sources' `
            "$kind initializer did not report the case-alias destination collision."
        Assert-Equal `
            (Get-TreeFingerprint $copyRoot) `
            $before `
            "$kind initializer mutated a case-insensitive case-alias fixture"
        return
    }

    Assert-ProcessSucceeded $result "$kind case-sensitive case-alias initialization"
    foreach ($entry in @(
        @('.initializer-case-alias/aA.txt', 'upper target'),
        @('.initializer-case-alias/aa.txt', 'lower target')
    )) {
        $path = Join-Path $copyRoot $entry[0]
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "$kind initializer falsely collapsed case-distinct destination $($entry[0])"
        }
        Assert-Equal `
            ([IO.File]::ReadAllText($path)) `
            $entry[1] `
            "$kind initializer changed case-distinct destination $($entry[0])"
    }
}

function Test-UnicodeCaseAliasDestinations(
    [ValidateSet('powershell', 'posix')][string]$kind
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-unicode-case-alias"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    $fixtureRoot = Join-Path $copyRoot '.initializer-unicode-alias'
    [void](New-Item -ItemType Directory -Path $fixtureRoot)
    Add-TextFixture $copyRoot '.initializer-unicode-alias/__ProjectName__Åa.txt' 'upper Unicode target'
    Add-TextFixture $copyRoot '.initializer-unicode-alias/aå__ProjectName__.txt' 'lower Unicode target'
    $aliases = Test-FileSystemAliases $fixtureRoot '.unicode-probe-aÅa.tmp' '.unicode-probe-aåa.tmp'
    $before = Get-TreeFingerprint $copyRoot
    $invocation = Get-InitializerInvocation `
        -kind $kind `
        -copyRoot $copyRoot `
        -author 'Unicode Tester' `
        -authorEmail 'unicode@example.com' `
        -ProjectName 'a'
    $result = Invoke-CapturedProcess `
        $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment

    if ($aliases) {
        if ($result.ExitCode -eq 0) {
            throw "$kind initializer accepted Unicode case-alias destinations"
        }
        Assert-DiagnosticContains $result `
            'is planned by multiple sources' `
            "$kind initializer did not report the Unicode case-alias destination collision."
        Assert-Equal `
            (Get-TreeFingerprint $copyRoot) `
            $before `
            "$kind initializer mutated a Unicode case-alias fixture"
        return
    }

    Assert-ProcessSucceeded $result "$kind Unicode case-distinct initialization"
    foreach ($entry in @(
        @('.initializer-unicode-alias/aÅa.txt', 'upper Unicode target'),
        @('.initializer-unicode-alias/aåa.txt', 'lower Unicode target')
    )) {
        $path = Join-Path $copyRoot $entry[0]
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "$kind initializer falsely collapsed Unicode-distinct destination $($entry[0])"
        }
        Assert-Equal `
            ([IO.File]::ReadAllText($path)) `
            $entry[1] `
            "$kind initializer changed Unicode-distinct destination $($entry[0])"
    }
}

function Test-PerDirectoryCaseSemantics(
    [ValidateSet('powershell', 'posix')][string]$kind
) {
    if (-not $IsWindows) {
        return
    }

    $copyRoot = Join-Path $script:TempRoot "$kind-per-directory-case"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    if (-not (Test-CaseInsensitiveFileSystem $copyRoot)) {
        Write-Host "Skipping $kind per-directory case fixture: temp root is already case-sensitive."
        return
    }

    $fixtureRoot = Join-Path $copyRoot '.initializer-per-directory-case'
    [void](New-Item -ItemType Directory -Path $fixtureRoot)
    $enable = Invoke-CapturedProcess `
        'fsutil.exe' `
        @('file', 'setCaseSensitiveInfo', $fixtureRoot, 'enable') `
        $copyRoot
    if ($enable.ExitCode -ne 0 -or (Test-CaseInsensitiveFileSystem $fixtureRoot)) {
        Write-Host "Skipping $kind per-directory case fixture: case-sensitive directory support is unavailable."
        return
    }

    Add-TextFixture $copyRoot '.initializer-per-directory-case/__ProjectName__A.txt' 'upper target'
    Add-TextFixture $copyRoot '.initializer-per-directory-case/a__ProjectName__.txt' 'lower target'
    $invocation = Get-InitializerInvocation `
        -kind $kind `
        -copyRoot $copyRoot `
        -author 'Per Directory Tester' `
        -authorEmail 'per-directory@example.com' `
        -ProjectName 'a'
    $result = Invoke-CapturedProcess `
        $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment
    Assert-ProcessSucceeded $result "$kind per-directory case-sensitive initialization"

    foreach ($entry in @(
        @('.initializer-per-directory-case/aA.txt', 'upper target'),
        @('.initializer-per-directory-case/aa.txt', 'lower target')
    )) {
        $path = Join-Path $copyRoot $entry[0]
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "$kind initializer ignored the destination directory's case semantics for $($entry[0])"
        }
        Assert-Equal `
            ([IO.File]::ReadAllText($path)) `
            $entry[1] `
            "$kind initializer changed per-directory case fixture $($entry[0])"
    }
}

function Test-PartialReservationMarkerFailure(
    [ValidateSet('powershell', 'posix')][string]$kind,
    [ValidateSet('none', 'file', 'directory', 'link')][string]$replacementKind = 'none'
) {
    $copyRoot = Join-Path `
        $script:TempRoot `
        "$kind-reservation-marker-failure-$replacementKind"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    $relativeSource = '.initializer-reservation-failure/a-__ProjectName__.txt'
    $relativeDestination = '.initializer-reservation-failure/a-init-security.txt'
    Add-TextFixture $copyRoot $relativeSource 'source must remain byte-identical'
    $before = Get-TreeFingerprint $copyRoot
    $destination = Join-Path $copyRoot $relativeDestination
    $externalContent = "external $replacementKind object must survive partial-marker cleanup"
    $linkTarget = Join-Path `
        $script:TempRoot `
        "$kind-partial-reservation-link-target"
    $invocation = Get-InitializerInvocation `
        $kind $copyRoot 'Reservation Tester' 'reservation@example.com'
    $invocation.Environment['INIT_SECURITY_TEST_FAIL_RESERVATION_MARKER'] = $relativeDestination
    if ($replacementKind -eq 'none') {
        $result = Invoke-CapturedProcess `
            $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment
    } else {
        $invocation.Environment['INIT_SECURITY_TEST_HOLD_AFTER_PARTIAL_RESERVATION_MARKER_FAILURE'] = `
            $relativeDestination
        $result = Invoke-CapturedProcessAtCheckpoint `
            $invocation.FileName `
            $invocation.Arguments `
            $copyRoot `
            $invocation.Environment `
            'INITIALIZER_TEST_PARTIAL_RESERVATION_MARKER_FAILED' `
            {
                [IO.Directory]::Delete($destination, $false)
                switch ($replacementKind) {
                    'file' {
                        Add-TextFixture $copyRoot $relativeDestination $externalContent
                    }
                    'directory' {
                        Add-DirectoryFixture $copyRoot $relativeDestination $externalContent
                    }
                    'link' {
                        [void](New-Item -ItemType Directory -Path $linkTarget)
                        Add-TextFixture $linkTarget 'marker.txt' $externalContent
                        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
                        [void](New-Item -ItemType $linkType -Path $destination -Target $linkTarget)
                    }
                }
            }

        if (-not $result.CheckpointObserved) {
            throw "$kind initializer did not expose the partial-reservation checkpoint.`nstdout:`n$($result.Stdout)`nstderr:`n$($result.Stderr)"
        }
    }

    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted an injected ownership-marker failure ($replacementKind)"
    }
    Assert-DiagnosticContains $result `
        $relativeDestination `
        "$kind initializer returned an unclear partial-reservation diagnostic."

    if ($replacementKind -eq 'none') {
        Assert-Equal `
            (Get-TreeFingerprint $copyRoot) `
            $before `
            "$kind initializer stranded or mutated data after a partial reservation"
        return
    }

    switch ($replacementKind) {
        'file' {
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                throw "$kind initializer deleted the partial-reservation replacement file"
            }
            Assert-Equal `
                ([IO.File]::ReadAllText($destination)) `
                $externalContent `
                "$kind initializer changed the partial-reservation replacement file"
        }
        'directory' {
            $marker = Join-Path $destination 'marker.txt'
            if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
                throw "$kind initializer deleted the partial-reservation replacement directory"
            }
            Assert-Equal `
                ([IO.File]::ReadAllText($marker)) `
                $externalContent `
                "$kind initializer changed the partial-reservation replacement directory"
        }
        'link' {
            $item = Get-Item -LiteralPath $destination -Force
            if (-not $item.LinkType) {
                throw "$kind initializer deleted the partial-reservation replacement link/reparse point"
            }
            Assert-Equal `
                ([IO.File]::ReadAllText((Join-Path $linkTarget 'marker.txt'))) `
                $externalContent `
                "$kind initializer changed the partial-reservation replacement link target"
        }
    }

    switch ($replacementKind) {
        'file' { [IO.File]::Delete($destination) }
        'directory' { [IO.Directory]::Delete($destination, $true) }
        'link' {
            if ($IsWindows) {
                [IO.Directory]::Delete($destination, $false)
            } else {
                [IO.File]::Delete($destination)
            }
        }
    }
    Assert-Equal `
        (Get-TreeFingerprint $copyRoot) `
        $before `
        "$kind initializer mutated the template around a replaced partial reservation"
}

function Test-ReservationReplacementAfterOwnershipCheck(
    [ValidateSet('powershell', 'posix')][string]$kind,
    [ValidateSet('file', 'directory', 'link')][string]$replacementKind
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-reservation-replacement-$replacementKind"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    $relativeSource = '.initializer-reservation-replacement/a-__ProjectName__.txt'
    $relativeDestination = '.initializer-reservation-replacement/a-init-security.txt'
    Add-TextFixture $copyRoot $relativeSource 'source must remain byte-identical'
    $before = Get-TreeFingerprint $copyRoot
    $destination = Join-Path $copyRoot $relativeDestination
    $externalContent = "external $replacementKind object must survive"
    $linkTarget = Join-Path $script:TempRoot "$kind-reservation-link-target"
    $invocation = Get-InitializerInvocation `
        $kind $copyRoot 'Reservation Race Tester' 'reservation-race@example.com'
    $invocation.Environment['INIT_SECURITY_TEST_HOLD_AFTER_RESERVATION_OWNERSHIP_CHECK'] = `
        $relativeDestination
    $result = Invoke-CapturedProcessAtCheckpoint `
        $invocation.FileName `
        $invocation.Arguments `
        $copyRoot `
        $invocation.Environment `
        'INITIALIZER_TEST_RESERVATION_OWNERSHIP_CHECKED' `
        {
            Remove-Item -LiteralPath $destination -Recurse -Force
            switch ($replacementKind) {
                'file' {
                    Add-TextFixture $copyRoot $relativeDestination $externalContent
                }
                'directory' {
                    Add-DirectoryFixture $copyRoot $relativeDestination $externalContent
                }
                'link' {
                    [void](New-Item -ItemType Directory -Path $linkTarget)
                    Add-TextFixture $linkTarget 'marker.txt' $externalContent
                    $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
                    [void](New-Item -ItemType $linkType -Path $destination -Target $linkTarget)
                }
            }
        }

    if (-not $result.CheckpointObserved) {
        throw "$kind initializer did not expose the reservation ownership-check checkpoint.`nstdout:`n$($result.Stdout)`nstderr:`n$($result.Stderr)"
    }
    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted a replaced reservation ($replacementKind)"
    }
    Assert-DiagnosticContains $result `
        $relativeDestination `
        "$kind initializer returned an unclear replaced-reservation diagnostic."

    switch ($replacementKind) {
        'file' {
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                throw "$kind initializer deleted the external replacement file"
            }
            Assert-Equal `
                ([IO.File]::ReadAllText($destination)) `
                $externalContent `
                "$kind initializer changed the external replacement file"
        }
        'directory' {
            $marker = Join-Path $destination 'marker.txt'
            if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
                throw "$kind initializer deleted the external non-empty replacement directory"
            }
            Assert-Equal `
                ([IO.File]::ReadAllText($marker)) `
                $externalContent `
                "$kind initializer changed the external replacement directory"
        }
        'link' {
            $item = Get-Item -LiteralPath $destination -Force
            if (-not $item.LinkType) {
                throw "$kind initializer deleted or replaced the external link/reparse point"
            }
            Assert-Equal `
                ([IO.File]::ReadAllText((Join-Path $linkTarget 'marker.txt'))) `
                $externalContent `
                "$kind initializer changed the external link target"
        }
    }

    switch ($replacementKind) {
        'file' { [IO.File]::Delete($destination) }
        'directory' { [IO.Directory]::Delete($destination, $true) }
        'link' {
            if ($IsWindows) {
                [IO.Directory]::Delete($destination, $false)
            } else {
                [IO.File]::Delete($destination)
            }
        }
    }
    Assert-Equal `
        (Get-TreeFingerprint $copyRoot) `
        $before `
        "$kind initializer mutated the template around a replaced reservation"
}

function Test-LateRaceRollback(
    [ValidateSet('powershell', 'posix')][string]$kind
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-late-race"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    Add-TextFixture `
        $copyRoot `
        '.initializer-race/a-__ProjectName__.txt' `
        'first source __Description__'
    Add-TextFixture `
        $copyRoot `
        '.initializer-race/z-__ProjectName__.txt' `
        'second source __Description__'
    $before = Get-TreeFingerprint $copyRoot
    $raceDestination = Join-Path $copyRoot '.initializer-race/z-init-security.txt'
    $raceContent = 'external destination must survive'
    $invocation = Get-InitializerInvocation `
        $kind $copyRoot 'Race Tester' 'race@example.com'
    $invocation.Environment['INIT_SECURITY_TEST_HOLD_AFTER_PREFLIGHT'] = '1'
    $result = Invoke-CapturedProcessAtCheckpoint `
        $invocation.FileName `
        $invocation.Arguments `
        $copyRoot `
        $invocation.Environment `
        'INITIALIZER_TEST_PREFLIGHT_READY' `
        { Add-TextFixture $copyRoot '.initializer-race/z-init-security.txt' $raceContent }

    if (-not $result.CheckpointObserved) {
        throw "$kind initializer did not expose the deterministic post-preflight checkpoint"
    }
    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted a destination created after preflight"
    }
    Assert-DiagnosticContains $result `
        "appeared after preflight; refusing to rename source '.initializer-race/z-__ProjectName__.txt'" `
        "$kind initializer returned an unclear late-race diagnostic."
    if (-not (Test-Path -LiteralPath $raceDestination -PathType Leaf)) {
        throw "$kind initializer rollback removed the external race destination"
    }
    Assert-Equal `
        ([IO.File]::ReadAllText($raceDestination)) `
        $raceContent `
        "$kind initializer rollback changed the external race destination"

    Remove-Item -LiteralPath $raceDestination -Force
    Assert-Equal `
        (Get-TreeFingerprint $copyRoot) `
        $before `
        "$kind initializer did not restore the original tree after a late race"
}

function Test-SourceDisappearedRaceRollback(
    [ValidateSet('powershell', 'posix')][string]$kind,
    [ValidateSet('rename', 'settings')][string]$operation
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-source-disappeared-$operation"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    $quarantine = Join-Path $script:TempRoot "$kind-source-disappeared-$operation-quarantine"

    if ($operation -eq 'rename') {
        $relativeSource = '.initializer-source-race/__ProjectName__-source'
        $relativeDestination = '.initializer-source-race/init-security-source'
        Add-DirectoryFixture $copyRoot $relativeSource 'planned source must stay quarantined'
        $source = Join-Path $copyRoot $relativeSource
        $destination = Join-Path $copyRoot $relativeDestination
        $externalMarker = Join-Path $destination 'marker.txt'
        $expectedDiagnostic = "appeared after preflight; refusing to rename source '$relativeSource'"
        $checkpointAction = {
            Move-Item -LiteralPath $source -Destination $quarantine
            Add-DirectoryFixture $copyRoot $relativeDestination 'independent destination must survive'
        }
    } else {
        $source = Join-Path $copyRoot '.claude/settings.json.template'
        $destination = Join-Path $copyRoot '.claude/settings.json'
        $externalMarker = $destination
        $expectedDiagnostic = "appeared after preflight; refusing to activate source '.claude/settings.json.template'"
        $checkpointAction = {
            Move-Item -LiteralPath $source -Destination $quarantine
            Add-TextFixture $copyRoot '.claude/settings.json' 'independent settings must survive'
        }
    }

    $before = Get-TreeFingerprint $copyRoot
    $invocation = Get-InitializerInvocation `
        $kind $copyRoot 'Source Race Tester' 'source-race@example.com'
    $invocation.Environment['INIT_SECURITY_TEST_HOLD_AFTER_PREFLIGHT'] = '1'
    $result = Invoke-CapturedProcessAtCheckpoint `
        $invocation.FileName `
        $invocation.Arguments `
        $copyRoot `
        $invocation.Environment `
        'INITIALIZER_TEST_PREFLIGHT_READY' `
        $checkpointAction

    if (-not $result.CheckpointObserved) {
        throw "$kind initializer did not expose the source-disappeared $operation checkpoint"
    }
    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted a disappeared $operation source and independent destination"
    }
    Assert-DiagnosticContains $result `
        $expectedDiagnostic `
        "$kind initializer returned an unclear source-disappeared $operation diagnostic."
    if (-not (Test-Path -LiteralPath $destination)) {
        throw "$kind initializer rollback removed or relocated the independent $operation destination"
    }
    if (-not (Test-Path -LiteralPath $quarantine)) {
        throw "$kind initializer rollback consumed the quarantined $operation source"
    }
    $externalContent = [IO.File]::ReadAllText($externalMarker)
    $expectedExternalContent = if ($operation -eq 'rename') {
        'independent destination must survive'
    } else {
        'independent settings must survive'
    }
    Assert-Equal `
        $externalContent `
        $expectedExternalContent `
        "$kind initializer rollback changed the independent $operation destination"

    Remove-Item -LiteralPath $destination -Recurse -Force
    Move-Item -LiteralPath $quarantine -Destination $source
    Assert-Equal `
        (Get-TreeFingerprint $copyRoot) `
        $before `
        "$kind initializer did not restore the original tree after the source-disappeared $operation race fixture was reset"
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
    if ($RaceOnly) {
        foreach ($kind in @('powershell', 'posix')) {
            Test-LateRaceRollback $kind
            foreach ($operation in @('rename', 'settings')) {
                Test-SourceDisappearedRaceRollback $kind $operation
            }
        }
        Write-Host 'Initializer late-race rollback checks passed.' -ForegroundColor Green
        return
    }

    if ($ReopenedOnly) {
        foreach ($kind in @('powershell', 'posix')) {
            Test-CaseAliasDestinations $kind
            Test-UnicodeCaseAliasDestinations $kind
            Test-PerDirectoryCaseSemantics $kind
            Test-PartialReservationMarkerFailure $kind
            foreach ($replacementKind in @('file', 'directory', 'link')) {
                Test-PartialReservationMarkerFailure $kind $replacementKind
            }
            foreach ($replacementKind in @('file', 'directory', 'link')) {
                Test-ReservationReplacementAfterOwnershipCheck $kind $replacementKind
            }
            foreach ($operation in @('rename', 'settings')) {
                Test-SourceDisappearedRaceRollback $kind $operation
            }
        }
        Write-Host 'Reopened initializer collision and rollback checks passed.' -ForegroundColor Green
        return
    }

    foreach ($phase in @('content', 'rename')) {
        Test-CheckedPosixTraversal $phase
    }
    foreach ($kind in @('powershell', 'posix')) {
        Test-CollisionMatrix $kind
        Test-CaseAliasDestinations $kind
        Test-UnicodeCaseAliasDestinations $kind
        Test-PerDirectoryCaseSemantics $kind
        Test-PartialReservationMarkerFailure $kind
        foreach ($replacementKind in @('file', 'directory', 'link')) {
            Test-PartialReservationMarkerFailure $kind $replacementKind
        }
        foreach ($replacementKind in @('file', 'directory', 'link')) {
            Test-ReservationReplacementAfterOwnershipCheck $kind $replacementKind
        }
        Test-LateRaceRollback $kind
        foreach ($operation in @('rename', 'settings')) {
            Test-SourceDisappearedRaceRollback $kind $operation
        }
    }
    Write-Host 'Initializer traversal, collision, and rollback checks passed.' -ForegroundColor Green
    if ($CollisionOnly) {
        return
    }

    Test-DiagnosticNormalization

    $ordinaryAuthor = 'Renée  O''Connor, "R&D" + QA'
    $ordinaryEmail = 'anne.o+release@example.com'
    $hostileAuthor = 'Eve "$(touch$IFS./init-security-name-owned)" #:[]{}&*!| suffix'
    $hostileEmail = 'attacker+$(touch$IFS./init-security-email-owned)@example.com'

    $psPlain = Test-SuccessfulInitialization powershell explicit plain-template `
        $ordinaryAuthor $ordinaryEmail -AddRenameFixtures:$false
    $shPlain = Test-SuccessfulInitialization posix explicit plain-template `
        $ordinaryAuthor $ordinaryEmail -AddRenameFixtures:$false
    Assert-Equal $shPlain $psPlain 'Initializers generated different plain-template release workflows'

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
