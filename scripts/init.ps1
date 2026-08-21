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

$gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
$gitPath = if ($gitCommand) { $gitCommand.Source } else { $null }

function Get-GitConfigValue([string]$key, [string]$executablePath) {
    if (-not $executablePath) {
        return $null
    }

    # PowerShell's native-output pipeline splits lines into an object array and
    # string coercion then joins them with spaces. Read NUL-delimited output as
    # one stream so validation sees the exact configured value instead.
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $executablePath
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
        try {
            $started = $process.Start()
        } catch [ComponentModel.Win32Exception] {
            return $null
        }
        if (-not $started) {
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
    $Author = Get-GitConfigValue 'user.name' $gitPath
    if (-not $Author) { $Author = 'Your Name' }
}
if (-not $AuthorEmail) {
    $AuthorEmail = Get-GitConfigValue 'user.email' $gitPath
    if (-not $AuthorEmail) { $AuthorEmail = 'you@example.com' }
}
if (-not $GitHubOwner) { $GitHubOwner = 'your-org' }
if (-not $Description) { $Description = 'TODO: crate description' }

function Test-ReleaseIdentityFallback([string]$value) {
    # Git removes angle brackets wherever they occur and trims this ASCII set
    # from identity boundaries. Keep the no-Git path aligned with that contract;
    # when Git is available, its formatter below remains the final authority.
    if ($value.Length -eq 0 -or $value.IndexOfAny([char[]]@([char]0, '<', '>')) -ge 0) {
        return $false
    }
    $boundaryCrud = [char[]]@(
        [char]0x20, [char]0x09, [char]0x0b, [char]0x0c,
        ',', ':', ';', '"', "'", '\'
    )
    return (
        [Array]::IndexOf($boundaryCrud, $value[0]) -lt 0 -and
        [Array]::IndexOf($boundaryCrud, $value[$value.Length - 1]) -lt 0
    )
}

function Assert-ReleaseIdentityValue(
    [string]$parameterName,
    [string]$value,
    [string]$executablePath
) {
    # Command substitution strips trailing newlines after decoding, and Git
    # identities are single-line values. Reject line breaks before touching the
    # template so both initializer paths have the same lossless contract.
    if ($value -match '[\r\n]') {
        throw "Invalid -${parameterName}: release identity values must be a single line; CR and LF characters are not supported."
    }
    if (-not (Test-ReleaseIdentityFallback $value)) {
        throw "Invalid -${parameterName}: release identity value is not preserved exactly when Git formats a commit identity; Git would strip or alter characters."
    }
    if (-not $executablePath) {
        return
    }

    # Git's ident formatter strips a wider set of boundary punctuation than its
    # config store does. Probe the formatter itself so accepted values have a
    # lossless contract even if that set changes, instead of maintaining a
    # second, inevitably incomplete blacklist in this initializer.
    $probeName = if ($parameterName -eq 'Author') { $value } else { 'Release Identity Probe' }
    $probeEmail = if ($parameterName -eq 'AuthorEmail') { $value } else { 'probe@example.invalid' }
    $expected = "$probeName <$probeEmail> 0 +0000"

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $executablePath
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
        try {
            $started = $process.Start()
        } catch [ComponentModel.Win32Exception] {
            return
        }
        if (-not $started) {
            return
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

Assert-ReleaseIdentityValue -parameterName 'Author' -value $Author -executablePath $gitPath
Assert-ReleaseIdentityValue -parameterName 'AuthorEmail' -value $AuthorEmail -executablePath $gitPath

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

function ConvertTo-TomlBasicStringContent(
    [string]$parameterName,
    [AllowEmptyString()][string]$value
) {
    # Tokens in .toml templates are basic-string content, not complete TOML
    # values. Use TOML's short escapes where available. Reject the remaining
    # C0 controls and DEL before the transaction starts rather than emitting a
    # manifest whose meaning depends on a parser's handling of literal controls.
    $escaped = [Text.StringBuilder]::new($value.Length)
    foreach ($character in $value.ToCharArray()) {
        $codePoint = [int]$character
        $replacement = switch ($codePoint) {
            0x08 { '\b'; break }
            0x09 { '\t'; break }
            0x0a { '\n'; break }
            0x0c { '\f'; break }
            0x0d { '\r'; break }
            0x22 { '\"'; break }
            0x5c { '\\'; break }
            default { $null }
        }
        if ($null -ne $replacement) {
            [void]$escaped.Append($replacement)
        } elseif ($codePoint -le 0x1f -or $codePoint -eq 0x7f) {
            $display = 'U+{0:X4}' -f $codePoint
            throw "Invalid -${parameterName}: control character $display is unsupported in TOML string input; no files were changed."
        } else {
            [void]$escaped.Append($character)
        }
    }
    $escaped.ToString()
}

# Values written into TOML files (Cargo.toml description/repository) sit inside
# double-quoted basic strings. Keep the serializer separate from ordinary text
# substitution so Markdown, YAML, and paths still receive the original value.
$tomlParameterNames = [ordered]@{
    '__ProjectName__' = 'ProjectName'
    '__Author__' = 'Author'
    '__AuthorEmail__' = 'AuthorEmail'
    '__GitHubOwner__' = 'GitHubOwner'
    '__Description__' = 'Description'
    '__Year__' = 'Year'
}
$tomlReplacements = [ordered]@{}
foreach ($key in $replacements.Keys) {
    $tomlReplacements[$key] = ConvertTo-TomlBasicStringContent `
        -parameterName $tomlParameterNames[$key] `
        -value $replacements[$key]
}
$tomlFileExtensions = @('.toml')

$templateTokenPattern = [Text.RegularExpressions.Regex]::new(
    '__(?:ProjectName|Author|AuthorEmail|GitHubOwner|Description|Year)__',
    [Text.RegularExpressions.RegexOptions]::CultureInvariant
)

function Expand-TemplateTokensSinglePass(
    [AllowEmptyString()][string]$text,
    [Collections.IDictionary]$replacementMap
) {
    # Enumerate matches from the original text before appending any values. A
    # replacement may itself contain a supported token spelling, but it never
    # becomes input to this matcher.
    $matches = $templateTokenPattern.Matches($text)
    if ($matches.Count -eq 0) {
        return $text
    }

    $expanded = [Text.StringBuilder]::new($text.Length)
    $cursor = 0
    foreach ($match in $matches) {
        [void]$expanded.Append($text, $cursor, $match.Index - $cursor)
        [void]$expanded.Append([string]$replacementMap[$match.Value])
        $cursor = $match.Index + $match.Length
    }
    [void]$expanded.Append($text, $cursor, $text.Length - $cursor)
    $expanded.ToString()
}

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

function Test-OrdinaryFile([string]$path) {
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        return (
            $item -is [IO.FileInfo] -and
            -not $item.PSIsContainer -and
            -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            -not $item.LinkType
        )
    } catch {
        return $false
    }
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

function Wait-ReservationCleanupCheckpoint(
    [string]$relativeDestination,
    [bool]$partialMarkerFailure
) {
    $heldDestination = if ($partialMarkerFailure) {
        $env:INIT_SECURITY_TEST_HOLD_AFTER_PARTIAL_RESERVATION_MARKER_FAILURE
    } else {
        $env:INIT_SECURITY_TEST_HOLD_AFTER_RESERVATION_OWNERSHIP_CHECK
    }
    if ($heldDestination -cne $relativeDestination) {
        return
    }

    $checkpoint = if ($partialMarkerFailure) {
        'INITIALIZER_TEST_PARTIAL_RESERVATION_MARKER_FAILED'
    } else {
        'INITIALIZER_TEST_RESERVATION_OWNERSHIP_CHECKED'
    }
    [Console]::Out.WriteLine($checkpoint)
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

function Remove-EmptyOrdinaryDirectory([string]$path, [string]$description) {
    # Keep the observable type/attribute/emptiness checks adjacent to the
    # non-recursive delete. They reject replacements present at cleanup time;
    # this path-based API is not an atomic identity guarantee against an
    # adversarial replacement in the final check/delete window.
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (
        -not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    ) {
        throw "$description is not an ordinary non-reparse directory"
    }

    $entries = [IO.Directory]::EnumerateFileSystemEntries($path).GetEnumerator()
    try {
        if ($entries.MoveNext()) {
            throw "$description is not empty"
        }
    } finally {
        $entries.Dispose()
    }

    [IO.Directory]::Delete($path, $false)
}

Write-Host "==> Initializing template as '$crateSafe'" -ForegroundColor Cyan

# Build and validate the complete repository inventory before the first
# repository mutation. Traversal is manual so excluded directories are pruned
# and a reparse point is classified without ever enumerating its target.
$siblingSh = Join-Path $PSScriptRoot 'init.sh'
$repositoryItems = [Collections.Generic.List[IO.FileSystemInfo]]::new()
$repositoryFiles = [Collections.Generic.List[IO.FileInfo]]::new()
$unsafeEntries = [Collections.Generic.List[string]]::new()
$pendingDirectories = [Collections.Generic.Stack[string]]::new()
$pendingDirectories.Push($repoRoot)

while ($pendingDirectories.Count -gt 0) {
    $directory = $pendingDirectories.Pop()
    try {
        # -Force keeps dot-prefixed and Hidden entries in the same inventory on
        # every platform; Test-Excluded prunes VCS and build directories before
        # any of their children can be inspected.
        $children = Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop
    } catch {
        throw "Could not traverse the complete repository tree at '$((Get-RelativeDisplayPath $directory))'; no files were changed: $($_.Exception.Message)"
    }

    foreach ($item in $children) {
        if (Test-Excluded $item.FullName) {
            continue
        }
        $relativePath = Get-RelativeDisplayPath $item.FullName
        if (
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $item.LinkType
        ) {
            $unsafeEntries.Add("'$relativePath' is a link or reparse point")
            continue
        }
        if ($item.PSIsContainer) {
            $repositoryItems.Add($item)
            $pendingDirectories.Push($item.FullName)
            continue
        }
        if ($item -is [IO.FileInfo]) {
            $repositoryItems.Add($item)
            $repositoryFiles.Add($item)
            continue
        }
        $unsafeEntries.Add("'$relativePath' is not a regular file or directory")
    }
}

if ($unsafeEntries.Count -gt 0) {
    throw "Initialization input preflight rejected unsafe filesystem entries; no files were changed:`n  $($unsafeEntries -join "`n  ")"
}

# Deepest paths run first so child renames do not invalidate parent sources.
# Ordinal relative-path ordering makes equal-depth plans reproducible.
$renamePlan = [Collections.Generic.List[object]]::new()
foreach ($item in ($repositoryItems | Where-Object { $_.Name.Contains('__ProjectName__') })) {
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

# The two initializers share one byte-level text contract: only ordinary files
# containing valid UTF-8 and no NUL byte are eligible for token replacement.
# Binary (NUL-containing) and unsupported (invalid UTF-8) regular files are
# deliberately left byte-for-byte unchanged. Required template control files
# must satisfy the contract so initialization cannot silently produce a broken
# repository.
$strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
$requiredTextPaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
[void]$requiredTextPaths.Add($releaseWorkflowPath)
[void]$requiredTextPaths.Add($ciWorkflowPath)
[void]$requiredTextPaths.Add([IO.Path]::GetFullPath((Join-Path $repoRoot 'Cargo.toml')))
$contentPlan = [Collections.Generic.List[object]]::new()
foreach ($file in ($repositoryFiles | Sort-Object FullName)) {
    if ($file.FullName -eq $selfPath -or $file.FullName -eq $siblingSh) {
        continue
    }

    $canonicalFile = [IO.Path]::GetFullPath($file.FullName)
    if (-not (Test-OrdinaryFile $file.FullName)) {
        throw "Content source '$((Get-RelativeDisplayPath $file.FullName))' changed during input preflight; refusing to read through it."
    }
    try {
        $originalBytes = [IO.File]::ReadAllBytes($file.FullName)
    } catch {
        throw "Could not read '$((Get-RelativeDisplayPath $file.FullName))' during input preflight; no files were changed: $($_.Exception.Message)"
    }

    $binary = [Array]::IndexOf[byte]($originalBytes, [byte]0) -ge 0
    $text = $null
    if (-not $binary) {
        try {
            $text = $strictUtf8.GetString($originalBytes)
        } catch [Text.DecoderFallbackException] { }
    }
    if ($binary -or $null -eq $text) {
        if ($requiredTextPaths.Contains($canonicalFile)) {
            $classification = if ($binary) { 'binary (contains NUL)' } else { 'unsupported (not valid UTF-8)' }
            throw "required template file '$((Get-RelativeDisplayPath $file.FullName))' is $classification; no files were changed."
        }
        continue
    }

    $map = if ($canonicalFile.Equals($releaseWorkflowPath, $pathComparison)) {
        $releaseWorkflowReplacements
    } elseif ($tomlFileExtensions -contains $file.Extension) {
        $tomlReplacements
    } else {
        $replacements
    }
    $new = Expand-TemplateTokensSinglePass $text $map
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
            ContentBytes = $strictUtf8.GetBytes($new)
            OriginalBytes = $originalBytes
        })
    }
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
            Wait-ReservationCleanupCheckpoint $reservation.RelativeDestination $false
            Remove-EmptyOrdinaryDirectory `
                $reservation.MarkerPath `
                'reservation ownership marker'
            if (Test-PathEntryExists $reservation.MarkerPath) {
                throw 'reservation ownership marker still exists after cleanup'
            }
        } else {
            Wait-ReservationCleanupCheckpoint $reservation.RelativeDestination $true
        }

        Remove-EmptyOrdinaryDirectory `
            $reservation.Destination `
            'destination reservation'
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
$contentRollbackJournal = [Collections.Generic.List[object]]::new()
$settingsActivated = $false
try {
    # 1) Replace tokens in file contents. Both initializers are skipped: they
    #    carry the literal token strings as search keys, so substituting inside
    #    them would corrupt the sibling script.
    foreach ($entry in $contentPlan) {
        if (-not (Test-OrdinaryFile $entry.Path)) {
            throw "Content source '$((Get-RelativeDisplayPath $entry.Path))' changed after preflight; refusing to write through it."
        }
        # A write can fail after truncating the file, so journal the verified
        # target immediately before the mutation attempt.
        $contentRollbackJournal.Add($entry)
        [IO.File]::WriteAllBytes($entry.Path, $entry.ContentBytes)
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

    foreach ($entry in $contentRollbackJournal) {
        try {
            if (-not (Test-OrdinaryFile $entry.Path)) {
                throw 'content path is no longer an ordinary file; refusing to restore through it'
            }
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
