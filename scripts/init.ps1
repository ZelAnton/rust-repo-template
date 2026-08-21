#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Initializes this template into a concrete Rust project.

.DESCRIPTION
    POSIX counterpart: scripts/init.sh — use whichever matches your shell.

    Replaces the placeholder tokens (__ProjectName__, __Author__, __AuthorEmail__,
    __GitHubOwner__, __Description__, __Year__) in file contents AND in file/folder
    names, then removes the template-only files (TEMPLATE.md,
    docs/AGENT-INIT-GUIDE.md, the initializer security regression harness and
    its CI step, and — unless -KeepScript — both initializers, init.ps1 and
    init.sh).

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

function Get-GitConfigValue([string]$key) {
    # PowerShell's native-output pipeline splits lines into an object array and
    # string coercion then joins them with spaces. Read NUL-delimited output as
    # one stream so validation sees the exact configured value instead.
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    [void]$startInfo.ArgumentList.Add('config')
    [void]$startInfo.ArgumentList.Add('--null')
    [void]$startInfo.ArgumentList.Add('--get')
    [void]$startInfo.ArgumentList.Add($key)

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            return $null
        }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $value = $stdout.GetAwaiter().GetResult()
        [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or -not $value.EndsWith("`0", [StringComparison]::Ordinal)) {
            return $null
        }
        return $value.Substring(0, $value.Length - 1)
    } finally {
        $process.Dispose()
    }
}

if (-not $Author) {
    $Author = Get-GitConfigValue 'user.name'
    if (-not $Author) { $Author = 'Your Name' }
}
if (-not $AuthorEmail) {
    $AuthorEmail = Get-GitConfigValue 'user.email'
    if (-not $AuthorEmail) { $AuthorEmail = 'you@example.com' }
}
if (-not $GitHubOwner) { $GitHubOwner = 'your-org' }
if (-not $Description) { $Description = 'TODO: crate description' }

function Assert-ReleaseIdentityValue([string]$parameterName, [string]$value) {
    # Command substitution strips trailing newlines after decoding, and Git
    # identities are single-line values. Reject line breaks before touching the
    # template so both initializer paths have the same lossless contract.
    if ($value -match '[\r\n]') {
        throw "Invalid -${parameterName}: release identity values must be a single line; CR and LF characters are not supported."
    }

    # Git's ident formatter strips a wider set of boundary punctuation than its
    # config store does. Probe the formatter itself so accepted values have a
    # lossless contract even if that set changes, instead of maintaining a
    # second, inevitably incomplete blacklist in this initializer.
    $probeName = if ($parameterName -eq 'Author') { $value } else { 'Release Identity Probe' }
    $probeEmail = if ($parameterName -eq 'AuthorEmail') { $value } else { 'probe@example.invalid' }
    $expected = "$probeName <$probeEmail> 0 +0000"

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $startInfo.Environment['GIT_AUTHOR_NAME'] = $probeName
    $startInfo.Environment['GIT_AUTHOR_EMAIL'] = $probeEmail
    $startInfo.Environment['GIT_AUTHOR_DATE'] = '@0 +0000'
    [void]$startInfo.ArgumentList.Add('var')
    [void]$startInfo.ArgumentList.Add('GIT_AUTHOR_IDENT')

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Invalid -${parameterName}: Git could not validate the release identity value."
        }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $rendered = $stdout.GetAwaiter().GetResult()
        [void]$stderr.GetAwaiter().GetResult()
        if ($rendered.EndsWith("`r`n", [StringComparison]::Ordinal)) {
            $rendered = $rendered.Substring(0, $rendered.Length - 2)
        } elseif ($rendered.EndsWith("`n", [StringComparison]::Ordinal)) {
            $rendered = $rendered.Substring(0, $rendered.Length - 1)
        }
        if ($process.ExitCode -ne 0 -or $rendered -cne $expected) {
            throw "Invalid -${parameterName}: release identity value is not preserved exactly when Git formats a commit identity; Git would strip or alter characters."
        }
    } finally {
        $process.Dispose()
    }
}

Assert-ReleaseIdentityValue -parameterName 'Author' -value $Author
Assert-ReleaseIdentityValue -parameterName 'AuthorEmail' -value $AuthorEmail

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

# In release.yml the author placeholders are data, not Bash source. Base64 keeps
# every shell/YAML metacharacter out of the serialized workflow while preserving
# the exact UTF-8 value for the quoted git-config calls at release time.
$releaseWorkflowReplacements = [ordered]@{}
foreach ($key in $replacements.Keys) {
    $releaseWorkflowReplacements[$key] = $replacements[$key]
}
$releaseWorkflowReplacements['__Author__'] = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes($Author)
)
$releaseWorkflowReplacements['__AuthorEmail__'] = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes($AuthorEmail)
)
$releaseWorkflowPath = [IO.Path]::GetFullPath(
    (Join-Path $repoRoot '.github/workflows/release.yml')
)
$ciWorkflowPath = [IO.Path]::GetFullPath(
    (Join-Path $repoRoot '.github/workflows/ci.yml')
)
$templateSecurityTestsPath = [IO.Path]::GetFullPath(
    (Join-Path $repoRoot 'tests/init-security')
)
$pathComparison = [StringComparison]::Ordinal
$templateOnlyCiPattern = [regex]::new(
    '(?ms)^[ \t]*# template-only-init-security: begin\r?\n.*?^[ \t]*# template-only-init-security: end\r?\n?'
)

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
    $canonicalPath = [IO.Path]::GetFullPath($fullPath)
    if (
        $canonicalPath.Equals($templateSecurityTestsPath, $pathComparison) -or
        $canonicalPath.StartsWith(
            $templateSecurityTestsPath + [IO.Path]::DirectorySeparatorChar,
            $pathComparison
        )
    ) {
        return $true
    }
    $rel = $fullPath.Substring($repoRoot.Length).TrimStart('\', '/')
    foreach ($seg in ($rel -split '[\\/]')) {
        if ($excludedDirs -contains $seg) { return $true }
    }
    return $false
}

function Test-PathEntryExists([string]$path) {
    try {
        [void](Get-Item -LiteralPath $path -Force -ErrorAction Stop)
        return $true
    } catch [System.Management.Automation.ItemNotFoundException] {
        return $false
    }
}

function Get-RelativeDisplayPath([string]$path) {
    [IO.Path]::GetRelativePath($repoRoot, [IO.Path]::GetFullPath($path)).Replace('\', '/')
}

# Directory.CreateDirectory treats an existing directory as success. The native
# primitives preserve mkdir's exclusive-create result, which is what lets the
# filesystem decide case, Unicode, normalization, and per-directory aliases
# without first touching a directory that belongs to somebody else.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace RustTemplateInit {
    public static class NativeDirectory {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateDirectoryW")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateDirectoryWindows(string path, IntPtr securityAttributes);

        [DllImport("libc", CharSet = CharSet.Ansi, SetLastError = true, EntryPoint = "mkdir")]
        private static extern int CreateDirectoryUnix(string path, uint mode);

        public static bool TryCreate(string path, out int error) {
            bool created;
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) {
                string nativePath = path.StartsWith(@"\\?\", StringComparison.Ordinal)
                    ? path
                    : path.StartsWith(@"\\", StringComparison.Ordinal)
                        ? @"\\?\UNC\" + path.Substring(2)
                        : @"\\?\" + path;
                created = CreateDirectoryWindows(nativePath, IntPtr.Zero);
            } else {
                created = CreateDirectoryUnix(path, 511) == 0; // 0777, restricted by the caller's umask.
            }
            error = created ? 0 : Marshal.GetLastWin32Error();
            return created;
        }
    }
}
'@

function New-ExclusiveDirectory([string]$path, [ref]$nativeError) {
    [RustTemplateInit.NativeDirectory]::TryCreate($path, $nativeError)
}

function Wait-ReservationCleanupCheckpoint([string]$relativeDestination) {
    if (
        $env:INIT_SECURITY_TEST_HOLD_AFTER_RESERVATION_OWNERSHIP_CHECK -cne
            $relativeDestination
    ) {
        return
    }

    [Console]::Out.WriteLine('INITIALIZER_TEST_RESERVATION_OWNERSHIP_CHECKED')
    if ($env:INIT_SECURITY_TEST_READY_FILE -and $env:INIT_SECURITY_TEST_RELEASE_FILE) {
        [IO.File]::WriteAllText($env:INIT_SECURITY_TEST_READY_FILE, 'ready')
        $checkpointDeadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath $env:INIT_SECURITY_TEST_RELEASE_FILE)) {
            if ([DateTime]::UtcNow -ge $checkpointDeadline) {
                throw 'Initializer reservation cleanup checkpoint was not released.'
            }
            Start-Sleep -Milliseconds 20
        }
    } elseif ([Console]::In.ReadLine() -cne 'continue') {
        throw 'Initializer reservation cleanup checkpoint was not released.'
    }
}

Write-Host "==> Initializing template as '$crateSafe'" -ForegroundColor Cyan

# Build every mutation plan before the first write. In particular, a path
# collision must not be discovered after content replacement has already
# changed the user's checkout.
$siblingSh = Join-Path $PSScriptRoot 'init.sh'

# Deepest paths run first so child renames do not invalidate parent sources.
# Ordinal relative-path ordering makes equal-depth plans reproducible.
$renamePlan = [Collections.Generic.List[object]]::new()
foreach ($item in (Get-ChildItem -Path $repoRoot -Recurse -Force | Where-Object {
    -not (Test-Excluded $_.FullName) -and $_.Name.Contains('__ProjectName__')
})) {
    $relativeSource = Get-RelativeDisplayPath $item.FullName
    $newName = $item.Name.Replace('__ProjectName__', $crateSafe)
    $destination = Join-Path (Split-Path -Parent $item.FullName) $newName
    $renamePlan.Add([pscustomobject]@{
        Source = $item.FullName
        Destination = $destination
        RelativeSource = $relativeSource
        RelativeDestination = Get-RelativeDisplayPath $destination
        Depth = ($relativeSource.ToCharArray() | Where-Object { $_ -eq '/' }).Count
        OriginalName = $item.Name
        NewName = $newName
    })
}
$renamePlan.Sort([Comparison[object]]{
    param($left, $right)
    $depthOrder = $right.Depth.CompareTo($left.Depth)
    if ($depthOrder -ne 0) { return $depthOrder }
    return [StringComparer]::Ordinal.Compare($left.RelativeSource, $right.RelativeSource)
})

$claudeTemplate = Join-Path $repoRoot '.claude/settings.json.template'
$claudeSettings = Join-Path $repoRoot '.claude/settings.json'
$activateClaudeSettings = Test-PathEntryExists $claudeTemplate
if ($activateClaudeSettings -and -not (Test-Path -LiteralPath $claudeTemplate -PathType Leaf)) {
    throw "Expected .claude/settings.json.template to be a file before initialization."
}

$collisions = [Collections.Generic.List[string]]::new()
$reservations = [Collections.Generic.List[object]]::new()

function Add-DestinationReservation(
    [string]$destination,
    [string]$relativeDestination,
    [string]$relativeSource
) {
    # Reserve the exact absent target with an exclusive mkdir in its real
    # parent. Record ownership before creating the nested nonce so a partial
    # marker failure cannot strand an untracked filesystem entry.
    $nativeError = 0
    if (New-ExclusiveDirectory $destination ([ref]$nativeError)) {
        $markerName = ".rust-template-init-reservation-$([guid]::NewGuid().ToString('N'))"
        $reservation = [pscustomobject]@{
            Destination = $destination
            RelativeDestination = $relativeDestination
            RelativeSource = $relativeSource
            MarkerPath = Join-Path $destination $markerName
            MarkerName = $markerName
            MarkerCreated = $false
        }
        # This append must remain immediately after the successful outer mkdir.
        $reservations.Add($reservation)

        if ($env:INIT_SECURITY_TEST_FAIL_RESERVATION_MARKER -ceq $relativeDestination) {
            $collisions.Add(
                "destination '$relativeDestination' ownership marker could not be created after reservation; no files were changed (source '$relativeSource')"
            )
            return
        }

        $markerError = 0
        if (-not (New-ExclusiveDirectory $reservation.MarkerPath ([ref]$markerError))) {
            $collisions.Add(
                "destination '$relativeDestination' ownership marker could not be created after reservation; filesystem error $markerError (source '$relativeSource')"
            )
            return
        }
        $reservation.MarkerCreated = $true
        return
    }

    $owner = $null
    foreach ($reservation in $reservations) {
        if (-not $reservation.MarkerCreated) {
            continue
        }
        $candidateMarker = Join-Path $destination $reservation.MarkerName
        try {
            $item = Get-Item -LiteralPath $candidateMarker -Force -ErrorAction Stop
            if (
                $item.PSIsContainer -and
                -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
            ) {
                $owner = $reservation
                break
            }
        } catch { }
    }

    if ($null -ne $owner) {
        $collisions.Add(
            "destination '$relativeDestination' is planned by multiple sources: '$($owner.RelativeSource)', '$relativeSource'"
        )
    } elseif (Test-PathEntryExists $destination) {
        $collisions.Add("destination '$relativeDestination' already exists (source '$relativeSource')")
    } else {
        $collisions.Add(
            "destination '$relativeDestination' could not be reserved; filesystem equivalence could not be established (native error $nativeError; source '$relativeSource')"
        )
    }
}

foreach ($entry in $renamePlan) {
    Add-DestinationReservation `
        $entry.Destination `
        $entry.RelativeDestination `
        $entry.RelativeSource
}
if ($activateClaudeSettings) {
    Add-DestinationReservation `
        $claudeSettings `
        (Get-RelativeDisplayPath $claudeSettings) `
        (Get-RelativeDisplayPath $claudeTemplate)
}

# Reservation cleanup is part of preflight, not the mutation transaction. Both
# removals are non-recursive: a replacement file, reparse point, or non-empty
# directory survives and makes initialization fail closed before template writes.
$reservationCleanupErrors = [Collections.Generic.List[string]]::new()
foreach ($reservation in $reservations) {
    try {
        if ($reservation.MarkerCreated) {
            $markerItem = Get-Item -LiteralPath $reservation.MarkerPath -Force -ErrorAction Stop
            if (
                -not $markerItem.PSIsContainer -or
                ($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint)
            ) {
                throw 'reservation ownership marker changed before cleanup'
            }
            Wait-ReservationCleanupCheckpoint $reservation.RelativeDestination
            [IO.Directory]::Delete($reservation.MarkerPath, $false)
            if (Test-PathEntryExists $reservation.MarkerPath) {
                throw 'reservation ownership marker still exists after cleanup'
            }
        }

        [IO.Directory]::Delete($reservation.Destination, $false)
        if (Test-PathEntryExists $reservation.Destination) {
            throw 'destination still exists after reservation cleanup'
        }
    } catch {
        $reservationCleanupErrors.Add(
            "destination '$($reservation.RelativeDestination)': $($_.Exception.Message)"
        )
    }
}
if ($reservationCleanupErrors.Count -gt 0) {
    throw "initialization destination reservation cleanup failed; no template files were changed:`n  $($reservationCleanupErrors -join "`n  ")"
}
if ($collisions.Count -gt 0) {
    throw "initialization collision preflight failed; no files were changed:`n  $($collisions -join "`n  ")"
}

# Validate and materialize the content plan only in memory. Any malformed
# template-only CI markers or unreadable file still fail before the first write.
$files = Get-ChildItem -Path $repoRoot -File -Recurse -Force | Where-Object {
    -not (Test-Excluded $_.FullName) -and $_.FullName -ne $selfPath -and $_.FullName -ne $siblingSh
}
$contentPlan = [Collections.Generic.List[object]]::new()
foreach ($file in $files) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    $new = $text
    $canonicalFile = [IO.Path]::GetFullPath($file.FullName)
    $map = if ($canonicalFile.Equals($releaseWorkflowPath, $pathComparison)) {
        $releaseWorkflowReplacements
    } elseif ($tomlFileExtensions -contains $file.Extension) {
        $tomlReplacements
    } else {
        $replacements
    }
    foreach ($key in $map.Keys) {
        $new = $new.Replace($key, $map[$key])
    }
    if ($canonicalFile.Equals($ciWorkflowPath, $pathComparison)) {
        $templateOnlyMatches = $templateOnlyCiPattern.Matches($new)
        if ($templateOnlyMatches.Count -ne 1) {
            throw "Expected exactly one template-only init-security block in .github/workflows/ci.yml; found $($templateOnlyMatches.Count)."
        }
        $new = $templateOnlyCiPattern.Replace($new, '', 1)
    }
    if ($new -cne $text) {
        $contentPlan.Add([pscustomobject]@{
            Path = $file.FullName
            Content = $new
            OriginalBytes = [System.IO.File]::ReadAllBytes($file.FullName)
        })
    }
}

if ($env:INIT_SECURITY_TEST_HOLD_AFTER_PREFLIGHT -eq '1') {
    [Console]::Out.WriteLine('INITIALIZER_TEST_PREFLIGHT_READY')
    if ($env:INIT_SECURITY_TEST_READY_FILE -and $env:INIT_SECURITY_TEST_RELEASE_FILE) {
        [IO.File]::WriteAllText($env:INIT_SECURITY_TEST_READY_FILE, 'ready')
        $checkpointDeadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath $env:INIT_SECURITY_TEST_RELEASE_FILE)) {
            if ([DateTime]::UtcNow -ge $checkpointDeadline) {
                throw 'Initializer security test checkpoint was not released.'
            }
            Start-Sleep -Milliseconds 20
        }
    } elseif ([Console]::In.ReadLine() -cne 'continue') {
        throw 'Initializer security test checkpoint was not released.'
    }
}

# Content changes and path/settings moves form one rollback domain. A late
# no-overwrite failure reverses completed moves first, then restores the exact
# original bytes at their original paths. Race-created destinations are never
# added to the journal and are therefore never removed by rollback.
$completedRenames = [Collections.Generic.List[object]]::new()
$settingsActivated = $false
try {
    # 1) Replace tokens in file contents. Both initializers are skipped: they
    #    carry the literal token strings as search keys, so substituting inside
    #    them would corrupt the sibling script.
    foreach ($entry in $contentPlan) {
        # UTF-8 without BOM, LF preserved — matches .gitattributes (eol=lf).
        [System.IO.File]::WriteAllText(
            $entry.Path,
            $entry.Content,
            (New-Object System.Text.UTF8Encoding($false))
        )
    }
    Write-Host "    Updated contents in $($contentPlan.Count) file(s)." -ForegroundColor DarkGray

    # 2) Execute the already validated one-to-one rename plan without overwrite.
    foreach ($entry in $renamePlan) {
        if (Test-PathEntryExists $entry.Destination) {
            throw "Destination '$($entry.RelativeDestination)' appeared after preflight; refusing to rename source '$($entry.RelativeSource)'."
        }
        Rename-Item -LiteralPath $entry.Source -NewName $entry.NewName -ErrorAction Stop
        $completedRenames.Add($entry)
        Write-Host "    Renamed $($entry.OriginalName) -> $($entry.NewName)" -ForegroundColor DarkGray
    }

    # 3) Activate Claude Code shared settings without overwrite.
    if ($activateClaudeSettings) {
        if (Test-PathEntryExists $claudeSettings) {
            throw "Destination '.claude/settings.json' appeared after preflight; refusing to activate source '.claude/settings.json.template'."
        }
        Move-Item -LiteralPath $claudeTemplate -Destination $claudeSettings -ErrorAction Stop
        $settingsActivated = $true
        Write-Host "    Activated .claude/settings.json" -ForegroundColor DarkGray
    }
} catch {
    $originalFailure = $_
    $rollbackErrors = [Collections.Generic.List[string]]::new()

    if ($settingsActivated) {
        try {
            if (Test-PathEntryExists $claudeTemplate) {
                # The move did not run. Any destination belongs to the racer.
            } elseif (Test-PathEntryExists $claudeSettings) {
                Move-Item -LiteralPath $claudeSettings -Destination $claudeTemplate -ErrorAction Stop
            } else {
                throw 'neither settings source nor destination exists during rollback'
            }
        } catch {
            $rollbackErrors.Add("settings: $($_.Exception.Message)")
        }
    }

    for ($i = $completedRenames.Count - 1; $i -ge 0; $i--) {
        $entry = $completedRenames[$i]
        try {
            if (Test-PathEntryExists $entry.Source) {
                # The planned move did not run; leave any destination alone.
            } elseif (Test-PathEntryExists $entry.Destination) {
                Move-Item -LiteralPath $entry.Destination -Destination $entry.Source -ErrorAction Stop
            } else {
                throw "neither source nor destination exists for '$($entry.RelativeSource)'"
            }
        } catch {
            $rollbackErrors.Add("rename '$($entry.RelativeDestination)': $($_.Exception.Message)")
        }
    }

    foreach ($entry in $contentPlan) {
        try {
            [System.IO.File]::WriteAllBytes($entry.Path, $entry.OriginalBytes)
        } catch {
            $rollbackErrors.Add("content '$((Get-RelativeDisplayPath $entry.Path))': $($_.Exception.Message)")
        }
    }

    if ($rollbackErrors.Count -gt 0) {
        throw "Initialization failed and rollback was incomplete: $($originalFailure.Exception.Message)`n  $($rollbackErrors -join "`n  ")"
    }
    throw $originalFailure
}

# 4) Remove template-only files. The agent guide is template meta — pitfalls are
#    logged back to the *template's* copy (see the guide), so the downstream repo
#    doesn't keep it.
$templateOnly = @('TEMPLATE.md', 'docs/AGENT-INIT-GUIDE.md')
foreach ($rel in $templateOnly) {
    $p = Join-Path $repoRoot $rel
    if (Test-Path $p) { Remove-Item -LiteralPath $p -Force }
}
$templateSecurityTests = Join-Path $repoRoot 'tests/init-security'
if (Test-Path -LiteralPath $templateSecurityTests) {
    Remove-Item -LiteralPath $templateSecurityTests -Recurse -Force
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
