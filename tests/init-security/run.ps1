#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [switch]$CollisionOnly,
    [switch]$RaceOnly,
    [switch]$ReopenedOnly,
    [switch]$ContentSafetyOnly,
    [switch]$GitFileOnly,
    [switch]$NoGitOnly,
    [switch]$DuplicateGitPathOnly,
    [switch]$ReleaseIdentityOnly,
    [switch]$TomlOnly,
    [switch]$SinglePassOnly,
    [switch]$PathTokenOnly
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
    # The initializer inventories and hashes a full template copy before this
    # semantic ready signal. Loaded Windows filesystems can exceed 30 seconds;
    # keep the wait bounded without substituting elapsed time for readiness.
    $checkpointDeadline = [DateTime]::UtcNow.AddMinutes(2)
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
    [string]$ProjectName = 'init-security',
    [string]$GitHubOwner = 'example',
    [string]$Description = 'Initializer security regression fixture'
) {
    if ($kind -eq 'powershell') {
        $arguments = @(
            '-NoProfile', '-File', (Join-Path $copyRoot 'scripts/init.ps1'),
            '-ProjectName', $ProjectName, '-GitHubOwner', $GitHubOwner,
            '-Description', $Description,
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
arguments=("$1" --project-name "$INIT_PROJECT_NAME" --github-owner "$INIT_GITHUB_OWNER" \
  --description "$INIT_DESCRIPTION" --year 2026)
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
            INIT_GITHUB_OWNER = $GitHubOwner
            INIT_DESCRIPTION = $Description
            INIT_USE_DEFAULT_AUTHOR = if ($UseDefaultAuthor) { '1' } else { '0' }
            INIT_USE_DEFAULT_AUTHOR_EMAIL = if ($UseDefaultAuthorEmail) { '1' } else { '0' }
            INIT_KEEP_SCRIPT = if ($KeepScript) { '1' } else { '0' }
        }
    }
}

function Add-TomlRoundTripFixture([string]$copyRoot) {
    Add-TextFixture $copyRoot '.initializer-toml-fixture/values.toml' @'
project = "__ProjectName__"
author = "__Author__"
author_email = "__AuthorEmail__"
github_owner = "__GitHubOwner__"
description = "__Description__"
year = "__Year__"
'@
}

function Read-TomlAsJson([string]$path, [string]$description) {
    $parser = Invoke-CapturedProcess $script:PythonPath @(
        '-c',
        'import json, pathlib, sys, tomllib; print(json.dumps(tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")), ensure_ascii=False))',
        $path
    ) (Split-Path -Parent $path) @{ PYTHONIOENCODING = 'utf-8' }
    Assert-ProcessSucceeded $parser $description
    $parser.Stdout | ConvertFrom-Json
}

function Test-TomlBasicStringRoundTrip(
    [ValidateSet('powershell', 'posix')][string]$kind,
    [string]$caseName,
    [string]$description,
    [string]$githubOwner
) {
    $expectedDescription = $description
    $expectedOwner = $githubOwner
    $copyRoot = Join-Path $script:TempRoot "$kind-toml-round-trip-$caseName"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    Add-TomlRoundTripFixture $copyRoot

    $author = 'TOML Round Trip Author'
    $authorEmail = 'toml-round-trip@example.com'
    $invocation = Get-InitializerInvocation $kind $copyRoot $author $authorEmail `
        -Description $expectedDescription -GitHubOwner $expectedOwner
    $result = Invoke-CapturedProcess `
        $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment
    Assert-ProcessSucceeded $result "$kind TOML basic-string round trip ($caseName)"

    $fixture = Read-TomlAsJson `
        (Join-Path $copyRoot '.initializer-toml-fixture/values.toml') `
        "$kind generated TOML fixture parse ($caseName)"
    Assert-Equal $fixture.project 'init-security' "$kind TOML project round trip failed ($caseName)"
    Assert-Equal $fixture.author $author "$kind TOML author round trip failed ($caseName)"
    Assert-Equal $fixture.author_email $authorEmail "$kind TOML author-email round trip failed ($caseName)"
    Assert-Equal $fixture.github_owner $expectedOwner "$kind TOML owner round trip failed ($caseName)"
    Assert-Equal $fixture.description $expectedDescription "$kind TOML description round trip failed ($caseName)"
    Assert-Equal $fixture.year '2026' "$kind TOML year round trip failed ($caseName)"

    # Cargo is the production parser for Cargo.toml. Its JSON view also proves
    # the parsed values were not double-escaped or otherwise normalized.
    $metadataResult = Invoke-CapturedProcess 'cargo' @(
        'metadata', '--no-deps', '--format-version', '1'
    ) $copyRoot
    Assert-ProcessSucceeded $metadataResult "$kind Cargo.toml parse ($caseName)"
    $package = ($metadataResult.Stdout | ConvertFrom-Json).packages[0]
    Assert-Equal `
        ([string]$package.description) `
        ([string]$expectedDescription) `
        "$kind Cargo description round trip failed ($caseName)"
    Assert-Equal `
        $package.repository `
        "https://github.com/$expectedOwner/init-security" `
        "$kind Cargo repository round trip failed ($caseName)"
}

function ConvertTo-PosixPath([string]$path) {
    if (-not $IsWindows) {
        return $path
    }
    $converted = Invoke-CapturedProcess $script:BashPath @(
        '-c', 'cygpath -u "$1"', 'toml-path-conversion', $path
    ) $script:TempRoot
    Assert-ProcessSucceeded $converted 'Git Bash temporary-path conversion'
    $converted.Stdout.Trim()
}

function Test-RejectedTomlControl(
    [ValidateSet('powershell', 'posix')][string]$kind,
    [string]$caseName,
    [char]$character,
    [string]$codePoint
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-toml-reject-$caseName"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    $transactionRoot = Join-Path $script:TempRoot "$kind-toml-reject-$caseName-transactions"
    [void](New-Item -ItemType Directory -Path $transactionRoot)

    $before = Get-TreeFingerprint $copyRoot
    $invocation = Get-InitializerInvocation `
        $kind $copyRoot 'Valid Author' 'valid@example.com' `
        -Description "before${character}after"
    if ($kind -eq 'posix') {
        $invocation.Environment['TMPDIR'] = ConvertTo-PosixPath $transactionRoot
    } else {
        $invocation.Environment['TEMP'] = $transactionRoot
        $invocation.Environment['TMP'] = $transactionRoot
    }
    $result = Invoke-CapturedProcess `
        $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment

    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted unsupported TOML control $codePoint ($caseName)"
    }
    Assert-DiagnosticContains $result `
        "control character $codePoint is unsupported in TOML string input; no files were changed" `
        "$kind initializer returned an unclear TOML-control diagnostic ($caseName)."
    Assert-Equal `
        (Get-TreeFingerprint $copyRoot) `
        $before `
        "$kind initializer mutated files before rejecting TOML control $codePoint ($caseName)"
    $artifacts = @(Get-ChildItem -LiteralPath $transactionRoot -Force)
    Assert-Equal `
        $artifacts.Count `
        0 `
        "$kind initializer created temporary transaction artifacts before rejecting TOML control $codePoint ($caseName)"
}

function Test-ShouldRunTomlSuite([bool]$tomlOnly, [bool]$hasOtherSelector) {
    $tomlOnly -or -not $hasOtherSelector
}

function Test-TomlSuiteRoutingContract {
    Assert-Equal `
        (Test-ShouldRunTomlSuite -tomlOnly:$false -hasOtherSelector:$false) `
        $true `
        'Default init-security routing omitted the TOML regression suite'
    Assert-Equal `
        (Test-ShouldRunTomlSuite -tomlOnly:$true -hasOtherSelector:$false) `
        $true `
        'Focused TOML routing omitted the TOML regression suite'
    Assert-Equal `
        (Test-ShouldRunTomlSuite -tomlOnly:$false -hasOtherSelector:$true) `
        $false `
        'A non-TOML focused selector unexpectedly enabled the TOML regression suite'
}

function Invoke-TomlBasicStringSuite {
    foreach ($kind in @('powershell', 'posix')) {
        Test-TomlBasicStringRoundTrip `
            $kind `
            'quotes-backslashes' `
            'quoted "value" with path\segment' `
            'owner"quoted\path'
        Test-TomlBasicStringRoundTrip `
            $kind `
            'short-controls' `
            "line one`nline two`rreturn`ttab`bbackspace`fform-feed" `
            "owner`ttab"
        foreach ($case in @(
            @{ Name = 'vertical-tab'; Character = [char]0x0b; CodePoint = 'U+000B' },
            @{ Name = 'escape'; Character = [char]0x1b; CodePoint = 'U+001B' },
            @{ Name = 'delete'; Character = [char]0x7f; CodePoint = 'U+007F' }
        )) {
            Test-RejectedTomlControl `
                $kind $case.Name $case.Character $case.CodePoint
        }
    }
    Write-Host 'Initializer TOML basic-string parity checks passed.' -ForegroundColor Green
}

function Get-SinglePassReplacementValues {
    $tokenSpellings = @(
        '__ProjectName__',
        '__Author__',
        '__AuthorEmail__',
        '__GitHubOwner__',
        '__Description__',
        '__Year__'
    )
    $tokenCorpus = $tokenSpellings -join '|'

    # ProjectName and Year have intentionally constrained output contracts (a
    # normalized crate slug and an integer). Every free-form replacement input
    # carries every token spelling so any rescan is observable.
    [ordered]@{
        ProjectName = 'single-pass-security'
        Author = "Author `"$tokenCorpus`" \ exact"
        AuthorEmail = "cascade+$($tokenSpellings -join '.')@example.com"
        GitHubOwner = "owner `"$tokenCorpus`" \ path`nowner-second-line"
        Description = "description `"$tokenCorpus`" \ path`ndescription-second-line"
        Year = '2026'
    }
}

function Add-SinglePassReplacementFixtures([string]$copyRoot) {
    Add-TextFixture $copyRoot '.initializer-single-pass/ordinary.txt' (@(
        'project=<__ProjectName__>'
        'author=<__Author__>'
        'author_email=<__AuthorEmail__>'
        'github_owner=<__GitHubOwner__>'
        'description=<__Description__>'
        'year=<__Year__>'
        'mixed=<__Author____Description____AuthorEmail____Year____GitHubOwner____ProjectName____Description__>'
    ) -join "`n")
    Add-TomlRoundTripFixture $copyRoot
}

function Test-SinglePassLiteralSubstitution(
    [ValidateSet('powershell', 'posix')][string]$kind
) {
    $values = Get-SinglePassReplacementValues
    $copyRoot = Join-Path $script:TempRoot "$kind-single-pass-literal"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    Add-SinglePassReplacementFixtures $copyRoot

    $invocation = Get-InitializerInvocation `
        $kind $copyRoot $values.Author $values.AuthorEmail `
        -ProjectName $values.ProjectName `
        -GitHubOwner $values.GitHubOwner `
        -Description $values.Description
    $result = Invoke-CapturedProcess `
        $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment
    Assert-ProcessSucceeded $result "$kind single-pass literal substitution"

    $ordinaryExpected = @(
        "project=<$($values.ProjectName)>"
        "author=<$($values.Author)>"
        "author_email=<$($values.AuthorEmail)>"
        "github_owner=<$($values.GitHubOwner)>"
        "description=<$($values.Description)>"
        "year=<$($values.Year)>"
        "mixed=<$($values.Author)$($values.Description)$($values.AuthorEmail)$($values.Year)$($values.GitHubOwner)$($values.ProjectName)$($values.Description)>"
    ) -join "`n"
    Assert-Equal `
        ([IO.File]::ReadAllText((Join-Path $copyRoot '.initializer-single-pass/ordinary.txt'))) `
        $ordinaryExpected `
        "$kind initializer rescanned a replacement value in ordinary text"

    $fixture = Read-TomlAsJson `
        (Join-Path $copyRoot '.initializer-toml-fixture/values.toml') `
        "$kind single-pass generated TOML fixture parse"
    foreach ($property in @(
        @{ Name = 'project'; Expected = $values.ProjectName },
        @{ Name = 'author'; Expected = $values.Author },
        @{ Name = 'author_email'; Expected = $values.AuthorEmail },
        @{ Name = 'github_owner'; Expected = $values.GitHubOwner },
        @{ Name = 'description'; Expected = $values.Description },
        @{ Name = 'year'; Expected = $values.Year }
    )) {
        Assert-Equal `
            $fixture.($property.Name) `
            $property.Expected `
            "$kind initializer rescanned or double-serialized $($property.Name) in TOML"
    }

    $cargo = Read-TomlAsJson `
        (Join-Path $copyRoot 'Cargo.toml') `
        "$kind single-pass Cargo.toml parse"
    Assert-Equal $cargo.package.description $values.Description `
        "$kind initializer changed the single-pass Cargo description"
    Assert-Equal `
        $cargo.package.repository `
        "https://github.com/$($values.GitHubOwner)/$($values.ProjectName)" `
        "$kind initializer changed the single-pass Cargo repository"
    Assert-ReleaseIdentityWorkflowUpdated `
        $copyRoot `
        "$kind single-pass literal substitution" `
        $values.Author `
        $values.AuthorEmail
}

function Test-ShouldRunSinglePassSuite([bool]$singlePassOnly, [bool]$hasOtherSelector) {
    $singlePassOnly -or -not $hasOtherSelector
}

function Test-SinglePassSuiteRoutingContract {
    Assert-Equal `
        (Test-ShouldRunSinglePassSuite -singlePassOnly:$false -hasOtherSelector:$false) `
        $true `
        'Default init-security routing omitted the single-pass regression suite'
    Assert-Equal `
        (Test-ShouldRunSinglePassSuite -singlePassOnly:$true -hasOtherSelector:$false) `
        $true `
        'Focused single-pass routing omitted the single-pass regression suite'
    Assert-Equal `
        (Test-ShouldRunSinglePassSuite -singlePassOnly:$false -hasOtherSelector:$true) `
        $false `
        'A non-single-pass focused selector unexpectedly enabled the single-pass regression suite'
}

function Invoke-SinglePassLiteralSubstitutionSuite {
    foreach ($kind in @('powershell', 'posix')) {
        Test-SinglePassLiteralSubstitution $kind
    }
    Write-Host 'Initializer single-pass literal substitution checks passed.' -ForegroundColor Green
}

function Get-PathTokenReplacementValues {
    [ordered]@{
        ProjectName = 'path-token-security'
        Author = 'Path Author'
        AuthorEmail = 'path@example.com'
        GitHubOwner = 'path-owner'
        Description = 'path-description'
        Year = '2026'
    }
}

function Add-PathTokenFixtures([string]$copyRoot) {
    Add-TextFixture `
        $copyRoot `
        '.initializer-path-tokens/__Author__-__AuthorEmail__/__GitHubOwner____Description____Year____ProjectName____ProjectName__.txt' `
        'path-token fixture'
}

function Test-PathTokenRenames(
    [ValidateSet('powershell', 'posix')][string]$kind
) {
    $values = Get-PathTokenReplacementValues
    $copyRoot = Join-Path $script:TempRoot "$kind-path-token-renames"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    Add-PathTokenFixtures $copyRoot
    $invocation = Get-InitializerInvocation `
        $kind $copyRoot $values.Author $values.AuthorEmail `
        -ProjectName $values.ProjectName `
        -GitHubOwner $values.GitHubOwner `
        -Description $values.Description
    $result = Invoke-CapturedProcess `
        $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment
    Assert-ProcessSucceeded $result "$kind path-token renames"

    $expected = Join-Path `
        $copyRoot `
        '.initializer-path-tokens/Path Author-path@example.com/path-ownerpath-description2026path-token-securitypath-token-security.txt'
    if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) {
        throw "$kind initializer did not replace every supported token in nested, repeated, and adjacent path names"
    }
    foreach ($stalePath in @(
        '.initializer-path-tokens/__Author__-__AuthorEmail__',
        '.initializer-path-tokens/Path Author-path@example.com/__GitHubOwner____Description____Year____ProjectName____ProjectName__.txt'
    )) {
        if (Test-Path -LiteralPath (Join-Path $copyRoot $stalePath)) {
            throw "$kind initializer retained stale token path $stalePath"
        }
    }
}

function Test-OpaquePathTokenReplacement(
    [ValidateSet('powershell', 'posix')][string]$kind
) {
    $values = Get-PathTokenReplacementValues
    $values.Description = 'opaque-__Author__-value'
    $copyRoot = Join-Path $script:TempRoot "$kind-path-token-opaque"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    Add-TextFixture $copyRoot '.initializer-path-tokens/opaque-__Description__.txt' 'opaque path fixture'
    $invocation = Get-InitializerInvocation `
        $kind $copyRoot $values.Author $values.AuthorEmail `
        -ProjectName $values.ProjectName `
        -GitHubOwner $values.GitHubOwner `
        -Description $values.Description
    $result = Invoke-CapturedProcess `
        $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment
    Assert-ProcessSucceeded $result "$kind opaque path-token replacement"
    $expected = Join-Path $copyRoot '.initializer-path-tokens/opaque-opaque-__Author__-value.txt'
    if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) {
        throw "$kind initializer rescanned an opaque path replacement value"
    }
}

function Test-RejectedPathToken(
    [ValidateSet('powershell', 'posix')][string]$kind,
    [ValidateSet('unsafe-value', 'unknown-token')][string]$caseName
) {
    $values = Get-PathTokenReplacementValues
    $copyRoot = Join-Path $script:TempRoot "$kind-path-token-reject-$caseName"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    if ($caseName -eq 'unsafe-value') {
        Add-TextFixture $copyRoot '.initializer-path-tokens/__Description__.txt' 'unsafe path fixture'
        $values.Description = 'unsafe/path'
        $expectedDiagnostic = 'unsupported or unsafe path token'
    } else {
        Add-TextFixture $copyRoot '.initializer-path-tokens/__Unsupported_Token__.txt' 'unknown path fixture'
        $expectedDiagnostic = 'unsupported path token'
    }
    $before = Get-TreeFingerprint $copyRoot
    $invocation = Get-InitializerInvocation `
        $kind $copyRoot $values.Author $values.AuthorEmail `
        -ProjectName $values.ProjectName `
        -GitHubOwner $values.GitHubOwner `
        -Description $values.Description
    $result = Invoke-CapturedProcess `
        $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment
    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted $caseName path-token input"
    }
    Assert-DiagnosticContains $result $expectedDiagnostic `
        "$kind initializer returned an unclear $caseName path-token diagnostic"
    Assert-DiagnosticContains $result 'no files were changed' `
        "$kind initializer omitted the no-mutation guarantee for $caseName path-token rejection"
    Assert-Equal `
        (Get-TreeFingerprint $copyRoot) `
        $before `
        "$kind initializer mutated the tree before rejecting $caseName path-token input"
}

function Invoke-PathTokenSuite {
    $fingerprints = [ordered]@{}
    foreach ($kind in @('powershell', 'posix')) {
        Test-PathTokenRenames $kind
        Test-OpaquePathTokenReplacement $kind
        Test-RejectedPathToken $kind 'unsafe-value'
        Test-RejectedPathToken $kind 'unknown-token'
        $fingerprints[$kind] = Get-TreeFingerprint `
            (Join-Path $script:TempRoot "$kind-path-token-renames")
    }
    Assert-Equal `
        $fingerprints.posix `
        $fingerprints.powershell `
        'PowerShell and POSIX initializers produced different path-token trees'
    Write-Host 'Initializer path-token contract checks passed.' -ForegroundColor Green
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

function Get-ExcludedTraversalFixtures {
    @(
        [pscustomobject]@{ Directory = '.git'; Id = 'git' },
        [pscustomobject]@{
            Directory = '.initializer-hidden-fixture/nested/.jj'
            Id = 'nested-jj'
        },
        [pscustomobject]@{
            Directory = '.initializer-hidden-fixture/nested/target'
            Id = 'nested-target'
        }
    )
}

function Add-ExcludedTraversalFixtures([string]$copyRoot) {
    $copyName = [IO.Path]::GetFileName($copyRoot)
    foreach ($fixture in (Get-ExcludedTraversalFixtures)) {
        $relativePath = "$($fixture.Directory)/__ProjectName__-excluded.txt"
        Add-TextFixture $copyRoot $relativePath 'excluded __ProjectName__ __Description__'

        $externalPath = Join-Path $script:TempRoot "$copyName-$($fixture.Id)-external.txt"
        [IO.File]::WriteAllText(
            $externalPath,
            'external __ProjectName__ __Description__',
            (New-Object Text.UTF8Encoding($false))
        )
        [void](New-Item `
            -ItemType HardLink `
            -Path (Join-Path $copyRoot "$($fixture.Directory)/unread-hard-link.txt") `
            -Target $externalPath `
            -ErrorAction Stop)
    }
}

function Assert-ReleaseIdentityWorkflowUpdated(
    [string]$copyRoot,
    [string]$description,
    [string]$author,
    [string]$authorEmail
) {
    $releaseWorkflow = [IO.File]::ReadAllText(
        (Join-Path $copyRoot '.github/workflows/release.yml')
    )
    foreach ($placeholder in @('__Author__', '__AuthorEmail__')) {
        if ($releaseWorkflow.Contains($placeholder)) {
            throw "$description left $placeholder unresolved in the hidden release workflow"
        }
    }
    foreach ($identity in @($author, $authorEmail)) {
        $encodedIdentity = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($identity))
        if (-not $releaseWorkflow.Contains($encodedIdentity)) {
            throw "$description did not update release identity data in the hidden release workflow"
        }
    }
}

function Assert-HiddenInitializerFixtureUpdated(
    [string]$copyRoot,
    [string]$description,
    [string]$author,
    [string]$authorEmail
) {
    $fixturePath = Join-Path $copyRoot '.initializer-hidden-fixture/init-security-fixture.txt'
    if (-not (Test-Path -LiteralPath $fixturePath)) {
        throw "$description did not rename a tokenized file inside a hidden directory"
    }
    Assert-Equal `
        ([IO.File]::ReadAllText($fixturePath)) `
        'Initializer security regression fixture' `
        "$description did not replace content inside a hidden directory"

    Assert-ReleaseIdentityWorkflowUpdated $copyRoot $description $author $authorEmail

    $copyName = [IO.Path]::GetFileName($copyRoot)
    foreach ($fixture in (Get-ExcludedTraversalFixtures)) {
        $relativePath = "$($fixture.Directory)/__ProjectName__-excluded.txt"
        $source = Join-Path $copyRoot $relativePath
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "$description renamed a tokenized path inside excluded directory $relativePath"
        }
        Assert-Equal `
            ([IO.File]::ReadAllText($source)) `
            'excluded __ProjectName__ __Description__' `
            "$description changed content inside excluded directory $relativePath"
        $renamed = Join-Path $copyRoot $relativePath.Replace('__ProjectName__', 'init-security')
        if (Test-Path -LiteralPath $renamed) {
            throw "$description created a renamed path inside excluded directory $relativePath"
        }

        $hardLink = Join-Path $copyRoot "$($fixture.Directory)/unread-hard-link.txt"
        if (-not (Test-Path -LiteralPath $hardLink -PathType Leaf)) {
            throw "$description changed an unread hard link inside excluded directory $($fixture.Directory)"
        }
        $externalPath = Join-Path $script:TempRoot "$copyName-$($fixture.Id)-external.txt"
        Assert-Equal `
            ([IO.File]::ReadAllText($externalPath)) `
            'external __ProjectName__ __Description__' `
            "$description read or changed a hard-link target from excluded directory $($fixture.Directory)"
    }
}

function Test-GitFileExclusion(
    [ValidateSet('powershell', 'posix')][string]$kind
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-gitfile"
    Copy-Template -source $script:RepoRoot -destination $copyRoot

    $gitFilePath = Join-Path $copyRoot '.git'
    $adminPath = Join-Path $script:TempRoot "$kind-__ProjectName__-admin"
    $gitInit = Invoke-CapturedProcess `
        'git' `
        @('init', '-q', '--separate-git-dir', $adminPath, $copyRoot) `
        $script:TempRoot
    Assert-ProcessSucceeded $gitInit "gitfile fixture setup for $kind initializer"

    $gitFileContent = [IO.File]::ReadAllText($gitFilePath)
    $externalPath = Join-Path $script:TempRoot "$kind-gitfile-external.txt"
    [IO.File]::WriteAllText(
        $externalPath,
        $gitFileContent,
        (New-Object Text.UTF8Encoding($false))
    )
    Remove-Item -LiteralPath $gitFilePath -Force
    [void](New-Item `
        -ItemType HardLink `
        -Path $gitFilePath `
        -Target $externalPath `
        -ErrorAction Stop)

    $invocation = Get-InitializerInvocation `
        $kind `
        $copyRoot `
        'Gitfile Fixture' `
        'gitfile@example.com'
    $result = Invoke-CapturedProcess `
        $invocation.FileName `
        $invocation.Arguments `
        $copyRoot `
        $invocation.Environment
    Assert-ProcessSucceeded $result "$kind initializer with .git gitfile"

    if (-not (Test-Path -LiteralPath $gitFilePath -PathType Leaf)) {
        throw "$kind initializer changed the excluded .git gitfile path"
    }
    Assert-Equal `
        ([IO.File]::ReadAllText($gitFilePath)) `
        $gitFileContent `
        "$kind initializer changed the excluded .git gitfile"
    Assert-Equal `
        ([IO.File]::ReadAllText($externalPath)) `
        $gitFileContent `
        "$kind initializer read or changed the excluded .git gitfile hard-link target"
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
        Add-ExcludedTraversalFixtures $copyRoot
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
        Assert-HiddenInitializerFixtureUpdated `
            $copyRoot `
            "$kind initializer ($source $caseName)" `
            $author `
            $authorEmail
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

function Test-PowerShellInitializationWithoutGit(
    [ValidateSet('defaults', 'explicit')][string]$source
) {
    $copyRoot = Join-Path $script:TempRoot "powershell-no-git-$source"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    $isolatedPath = Join-Path $script:TempRoot "empty-path-$source"
    [void](New-Item -ItemType Directory -Path $isolatedPath)
    $environment = @{ PATH = $isolatedPath }

    $probe = @'
$command = Get-Command git -CommandType Application -ErrorAction SilentlyContinue
if ($command) { exit 1 }
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = 'git'
$startInfo.UseShellExecute = $false
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
try {
    if ($process.Start()) {
        $process.Kill($true)
        exit 1
    }
    exit 0
} catch [ComponentModel.Win32Exception] {
    exit 0
} finally {
    $process.Dispose()
}
exit 1
'@
    $unavailable = Invoke-CapturedProcess `
        $script:PwshPath @('-NoProfile', '-Command', $probe) $copyRoot $environment
    Assert-ProcessSucceeded $unavailable "PowerShell no-Git environment probe ($source)"

    $expectedAuthor = if ($source -eq 'defaults') { 'Your Name' } else { 'Explicit Author' }
    $expectedEmail = if ($source -eq 'defaults') { 'you@example.com' } else { 'explicit@example.com' }
    $useDefaults = $source -eq 'defaults'
    $invocation = Get-InitializerInvocation powershell $copyRoot $expectedAuthor $expectedEmail `
        -UseDefaultAuthor:$useDefaults -UseDefaultAuthorEmail:$useDefaults
    $invocation.Environment = $environment
    $result = Invoke-CapturedProcess `
        $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment
    Assert-ProcessSucceeded $result "PowerShell initializer without Git ($source)"
    Assert-TemplateOnlySecurityArtifactsRemoved $copyRoot "PowerShell initializer without Git ($source)"

    $verification = Invoke-CapturedProcess $script:PythonPath @(
        $script:VerifierPath, '--repo', $copyRoot, '--bash', $script:BashPath,
        '--expected-name', $expectedAuthor, '--expected-email', $expectedEmail
    ) $copyRoot
    Assert-ProcessSucceeded $verification "PowerShell no-Git workflow verification ($source)"
}

function Test-PowerShellDuplicateGitPathDiscovery {
    if ($IsWindows) {
        Write-Host 'Skipping duplicate-Git PATH fixture: the regression targets Unix executable aliases.'
        return
    }

    $copyRoot = Join-Path $script:TempRoot 'powershell-duplicate-git-path'
    Copy-Template -source $script:RepoRoot -destination $copyRoot

    $gitCommands = @(Get-Command git -CommandType Application -ErrorAction Stop)
    $realGit = $gitCommands[0].Source
    $aliasDirectories = foreach ($suffix in @('first', 'second')) {
        $directory = Join-Path $script:TempRoot "duplicate-git-path-$suffix"
        [void](New-Item -ItemType Directory -Path $directory)
        [void][IO.File]::CreateSymbolicLink((Join-Path $directory 'git'), $realGit)
        $directory
    }
    $environment = @{ PATH = $aliasDirectories -join [IO.Path]::PathSeparator }

    $author = '.Duplicate Git Path Author.'
    $authorEmail = '.duplicate-git-path@example.com.'
    $init = Invoke-CapturedProcess $realGit @('init', '-q') $copyRoot
    Assert-ProcessSucceeded $init 'git init for duplicate-Git PATH fixture'
    foreach ($entry in @(
        @('user.name', $author),
        @('user.email', $authorEmail)
    )) {
        $configured = Invoke-CapturedProcess `
            $realGit @('config', '--local', $entry[0], $entry[1]) $copyRoot
        Assert-ProcessSucceeded $configured "git config for duplicate-Git PATH fixture ($($entry[0]))"
    }

    $probe = @'
$commands = @(Get-Command git -CommandType Application -ErrorAction Stop)
if ($commands.Count -lt 2) { exit 1 }
'@
    $discovery = Invoke-CapturedProcess `
        $script:PwshPath @('-NoProfile', '-Command', $probe) $copyRoot $environment
    Assert-ProcessSucceeded $discovery 'PowerShell duplicate-Git PATH environment probe'

    $invocation = Get-InitializerInvocation powershell $copyRoot $author $authorEmail `
        -UseDefaultAuthor -UseDefaultAuthorEmail
    $invocation.Environment = $environment
    $result = Invoke-CapturedProcess `
        $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment
    Assert-ProcessSucceeded $result 'PowerShell initializer with duplicate Git PATH entries'
    Assert-ReleaseIdentityWorkflowUpdated `
        $copyRoot 'PowerShell initializer with duplicate Git PATH entries' $author $authorEmail

    $verification = Invoke-CapturedProcess $script:PythonPath @(
        $script:VerifierPath, '--repo', $copyRoot, '--bash', $script:BashPath,
        '--expected-name', $author, '--expected-email', $authorEmail
    ) $copyRoot
    Assert-ProcessSucceeded $verification 'PowerShell duplicate-Git PATH workflow verification'
}

function Test-SafeContentSuccess(
    [ValidateSet('powershell', 'posix')][string]$kind
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-safe-content"
    Copy-Template -source $script:RepoRoot -destination $copyRoot

    $largePath = Join-Path $copyRoot '.initializer-content/large.txt'
    $largeOriginal = "large-prefix-__ProjectName__-" + ('x' * 200000) + '-__Description__-large-suffix'
    Add-TextFixture $copyRoot '.initializer-content/large.txt' $largeOriginal

    $binaryPath = Join-Path $copyRoot '.initializer-content/binary.bin'
    $binaryBytes = [Collections.Generic.List[byte]]::new()
    $binaryBytes.AddRange([Text.Encoding]::UTF8.GetBytes('binary-__ProjectName__-'))
    $binaryBytes.Add(0)
    $binaryBytes.AddRange([Text.Encoding]::UTF8.GetBytes('-__Description__-tail'))
    [IO.File]::WriteAllBytes($binaryPath, $binaryBytes.ToArray())
    $binaryHash = (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash

    $unsupportedPath = Join-Path $copyRoot '.initializer-content/unsupported.dat'
    $unsupportedBytes = [byte[]](0x66, 0x6f, 0x80, 0xff, 0x5f, 0x5f, 0x59, 0x65, 0x61, 0x72, 0x5f, 0x5f)
    [IO.File]::WriteAllBytes($unsupportedPath, $unsupportedBytes)
    $unsupportedHash = (Get-FileHash -LiteralPath $unsupportedPath -Algorithm SHA256).Hash

    $invocation = Get-InitializerInvocation `
        $kind $copyRoot 'Content Tester' 'content@example.com'
    $result = Invoke-CapturedProcess `
        $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment
    Assert-ProcessSucceeded $result "$kind safe-content initializer"

    $largeExpected = $largeOriginal.Replace('__ProjectName__', 'init-security').Replace(
        '__Description__',
        'Initializer security regression fixture'
    )
    Assert-Equal `
        ([IO.File]::ReadAllText($largePath, [Text.UTF8Encoding]::new($false, $true))) `
        $largeExpected `
        "$kind initializer lost data while replacing a 200000-byte text file"
    Assert-Equal `
        ((Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash) `
        $binaryHash `
        "$kind initializer changed a binary file containing template token bytes"
    Assert-Equal `
        ((Get-FileHash -LiteralPath $unsupportedPath -Algorithm SHA256).Hash) `
        $unsupportedHash `
        "$kind initializer changed an invalid-UTF-8 regular file"

    @(
        (Get-FileHash -LiteralPath $largePath -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $unsupportedPath -Algorithm SHA256).Hash
    ) -join ':'
}

function Test-LinkPreflightFailure(
    [ValidateSet('powershell', 'posix')][string]$kind
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-link-input"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    Add-TextFixture $copyRoot '.initializer-content/earlier.txt' 'earlier __Description__ must remain unchanged'

    $externalPath = Join-Path $script:TempRoot "$kind-external-link-target.txt"
    $externalContent = 'external __Description__ target must remain unchanged'
    [IO.File]::WriteAllText($externalPath, $externalContent, [Text.UTF8Encoding]::new($false))
    $linkPath = Join-Path $copyRoot '.initializer-content/file-link.txt'
    try {
        [void](New-Item -ItemType SymbolicLink -Path $linkPath -Target $externalPath -ErrorAction Stop)
    } catch {
        # Windows may require an elevated token for symbolic links. A hard link
        # exercises the same no-write-through contract without that privilege.
        [void](New-Item -ItemType HardLink -Path $linkPath -Target $externalPath -ErrorAction Stop)
    }

    $before = Get-TreeFingerprint $copyRoot
    $invocation = Get-InitializerInvocation `
        $kind $copyRoot 'Link Tester' 'link@example.com'
    $result = Invoke-CapturedProcess `
        $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment
    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted a file link in the repository input tree"
    }
    Assert-DiagnosticContains $result `
        "'.initializer-content/file-link.txt' is a link or reparse point" `
        "$kind initializer returned an unclear file-link preflight diagnostic."
    Assert-Equal `
        ([IO.File]::ReadAllText($externalPath)) `
        $externalContent `
        "$kind initializer changed a target outside the repository through a file link"
    Assert-Equal `
        (Get-TreeFingerprint $copyRoot) `
        $before `
        "$kind initializer partially initialized files before rejecting a file link"
}

function Test-RequiredBinaryPreflightFailure(
    [ValidateSet('powershell', 'posix')][string]$kind
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-required-binary"
    Copy-Template -source $script:RepoRoot -destination $copyRoot
    Add-TextFixture $copyRoot '.initializer-content/earlier.txt' 'earlier __Description__ must remain unchanged'
    $cargoPath = Join-Path $copyRoot 'Cargo.toml'
    $cargoBytes = [Collections.Generic.List[byte]]::new()
    $cargoBytes.AddRange([IO.File]::ReadAllBytes($cargoPath))
    $cargoBytes.Add(0)
    $cargoBytes.AddRange([Text.Encoding]::UTF8.GetBytes('__Description__'))
    [IO.File]::WriteAllBytes($cargoPath, $cargoBytes.ToArray())

    $before = Get-TreeFingerprint $copyRoot
    $invocation = Get-InitializerInvocation `
        $kind $copyRoot 'Binary Tester' 'binary@example.com'
    $result = Invoke-CapturedProcess `
        $invocation.FileName $invocation.Arguments $copyRoot $invocation.Environment
    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted binary data in required Cargo.toml"
    }
    Assert-DiagnosticContains $result `
        "required template file 'Cargo.toml' is binary (contains NUL); no files were changed" `
        "$kind initializer returned an unclear required-binary diagnostic."
    Assert-Equal `
        (Get-TreeFingerprint $copyRoot) `
        $before `
        "$kind initializer changed earlier files before rejecting required binary data"
}

function Test-PostPreflightHardLinkRollback(
    [ValidateSet('powershell', 'posix')][string]$kind
) {
    $copyRoot = Join-Path $script:TempRoot "$kind-post-preflight-hard-link"
    Copy-Template -source $script:RepoRoot -destination $copyRoot

    $earlierRelative = '.initializer-post-preflight-content/a-earlier.txt'
    $lateRelative = '.initializer-post-preflight-content/z-late.txt'
    $earlierOriginal = 'earlier __Description__ must be restored'
    Add-TextFixture $copyRoot $earlierRelative $earlierOriginal
    Add-TextFixture $copyRoot $lateRelative 'late __Description__ must never reach an external inode'
    $earlierPath = Join-Path $copyRoot $earlierRelative
    $latePath = Join-Path $copyRoot $lateRelative

    $externalPath = Join-Path $script:TempRoot "$kind-post-preflight-hard-link-target.txt"
    $externalContent = 'external __Description__ target must remain unchanged'
    [IO.File]::WriteAllText($externalPath, $externalContent, [Text.UTF8Encoding]::new($false))

    $invocation = Get-InitializerInvocation `
        $kind $copyRoot 'Hard Link Race Tester' 'hard-link-race@example.com'
    $invocation.Environment['INIT_SECURITY_TEST_HOLD_AFTER_PREFLIGHT'] = '1'
    $result = Invoke-CapturedProcessAtCheckpoint `
        $invocation.FileName `
        $invocation.Arguments `
        $copyRoot `
        $invocation.Environment `
        'INITIALIZER_TEST_PREFLIGHT_READY' `
        {
            Remove-Item -LiteralPath $latePath -Force
            [void](New-Item -ItemType HardLink -Path $latePath -Target $externalPath -ErrorAction Stop)
        }

    if (-not $result.CheckpointObserved) {
        throw "$kind initializer did not expose the deterministic post-preflight hard-link checkpoint"
    }
    if ($result.ExitCode -eq 0) {
        throw "$kind initializer accepted a content source replaced by a hard link after preflight"
    }
    Assert-DiagnosticContains $result `
        "source '$lateRelative' changed after preflight; refusing to write through it." `
        "$kind initializer returned an unclear post-preflight hard-link diagnostic."
    Assert-Equal `
        ([IO.File]::ReadAllText($externalPath)) `
        $externalContent `
        "$kind initializer changed an external target through a post-preflight hard link"
    Assert-Equal `
        ([IO.File]::ReadAllText($earlierPath)) `
        $earlierOriginal `
        "$kind initializer did not roll back content written before rejecting a post-preflight hard link"
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
    $hasNonTomlSelector = [bool](
        $CollisionOnly -or $RaceOnly -or $ReopenedOnly -or $ContentSafetyOnly -or
        $GitFileOnly -or $NoGitOnly -or $DuplicateGitPathOnly -or $ReleaseIdentityOnly -or
        $SinglePassOnly -or $PathTokenOnly
    )
    $hasNonSinglePassSelector = [bool](
        $CollisionOnly -or $RaceOnly -or $ReopenedOnly -or $ContentSafetyOnly -or
        $GitFileOnly -or $NoGitOnly -or $DuplicateGitPathOnly -or $ReleaseIdentityOnly -or
        $TomlOnly -or $PathTokenOnly
    )
    $runTomlSuite = Test-ShouldRunTomlSuite `
        -tomlOnly:$TomlOnly `
        -hasOtherSelector:$hasNonTomlSelector
    $runSinglePassSuite = Test-ShouldRunSinglePassSuite `
        -singlePassOnly:$SinglePassOnly `
        -hasOtherSelector:$hasNonSinglePassSelector
    Test-TomlSuiteRoutingContract
    Test-SinglePassSuiteRoutingContract

    if ($TomlOnly) {
        Test-DiagnosticNormalization
        if (-not $runTomlSuite) {
            throw 'Internal routing error: -TomlOnly did not select the TOML regression suite'
        }
        Invoke-TomlBasicStringSuite
        return
    }

    if ($SinglePassOnly) {
        if (-not $runSinglePassSuite) {
            throw 'Internal routing error: -SinglePassOnly did not select the single-pass regression suite'
        }
        Invoke-SinglePassLiteralSubstitutionSuite
        return
    }

    if ($PathTokenOnly) {
        Invoke-PathTokenSuite
        return
    }

    if ($NoGitOnly) {
        foreach ($source in @('defaults', 'explicit')) {
            Test-PowerShellInitializationWithoutGit $source
        }
        Write-Host 'PowerShell initializer no-Git fallback checks passed.' -ForegroundColor Green
        return
    }

    if ($DuplicateGitPathOnly) {
        Test-PowerShellDuplicateGitPathDiscovery
        Write-Host 'PowerShell duplicate-Git PATH discovery check passed.' -ForegroundColor Green
        return
    }

    if ($GitFileOnly) {
        foreach ($kind in @('powershell', 'posix')) {
            Test-GitFileExclusion $kind
        }
        Write-Host 'Initializer .git gitfile exclusion checks passed.' -ForegroundColor Green
        return
    }

    if (-not $ReleaseIdentityOnly) {
    $psContent = Test-SafeContentSuccess powershell
    $shContent = Test-SafeContentSuccess posix
    Assert-Equal $shContent $psContent 'Initializers produced different safe-content bytes'
    foreach ($kind in @('powershell', 'posix')) {
        Test-GitFileExclusion $kind
        Test-LinkPreflightFailure $kind
        Test-RequiredBinaryPreflightFailure $kind
        Test-PostPreflightHardLinkRollback $kind
    }
    if ($ContentSafetyOnly) {
        Write-Host 'Initializer large-text, binary, unsupported-data, and link safety checks passed.' -ForegroundColor Green
        return
    }

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
    }

    Test-DiagnosticNormalization

    if ($runTomlSuite) {
        Invoke-TomlBasicStringSuite
    }

    if ($runSinglePassSuite) {
        Invoke-SinglePassLiteralSubstitutionSuite
    }

    Invoke-PathTokenSuite

    Test-PowerShellDuplicateGitPathDiscovery

    foreach ($source in @('defaults', 'explicit')) {
        Test-PowerShellInitializationWithoutGit $source
    }

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
