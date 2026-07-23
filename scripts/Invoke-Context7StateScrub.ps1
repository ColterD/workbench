<#
.SYNOPSIS
    Audit or scrub Context7 API keys (ctx7sk-...) out of local Codex state:
    .codex-global-state.json (and its .bak) plus sessions/ and
    archived_sessions/ rollout-*.jsonl files under the Codex home. Key VALUES
    are never printed, logged, or written anywhere — only 12-character
    SHA-256 fingerprints appear in the report. Idempotent: Audit changes
    nothing, and a repeated Scrub finds and removes zero occurrences.
.PARAMETER Mode
    Audit (default) reports occurrences without modifying any file.
    Scrub redacts keys in place ([REDACTED_CONTEXT7_KEY:<fingerprint>]),
    then re-scans and fails unless zero occurrences remain.
.PARAMETER CodexHome
    Codex state directory. Defaults to ~\.codex.
.PARAMETER ReportPath
    JSON report destination. Must live OUTSIDE the Codex home; the report
    is never written over a state target. Defaults to
    $env:LOCALAPPDATA\Context7StateScrub\context7-scrub-report.json.
.PARAMETER RipgrepPath
    Explicit rg.exe path; resolved from PATH when omitted. ripgrep is
    required (winget install BurntSushi.ripgrep.MSVC).
.PARAMETER ScanTimeoutSeconds
    Bounded wait for each ripgrep pass (30-3600, default 900).
.PARAMETER CloseAndRelaunchCodex
    Scrub mode only: gracefully close the Codex GUI first so it cannot
    rewrite state mid-scrub, and relaunch it afterwards.
.PARAMETER StartDelaySeconds
    Optional delay before starting (0-60, default 0).
.PARAMETER GraceSeconds
    GUI shutdown grace period for -CloseAndRelaunchCodex (5-120, default 45).
.EXAMPLE
    pwsh -File Invoke-Context7StateScrub.ps1
.EXAMPLE
    pwsh -File Invoke-Context7StateScrub.ps1 -Mode Scrub -CloseAndRelaunchCodex
.NOTES
    Exit 0 on success (report written); nonzero means refused or failed
    closed. Every target is validated (strict UTF-8, valid JSON/JSONL)
    before ANY target is modified. Writes are atomic (temp file +
    MoveFileEx replace) and preserve BOM, line endings, timestamps,
    attributes, and ACLs; no secret-bearing backup is ever created.
    Reparse points (junctions/symlinks), UNC/device-namespace paths, and
    alternate data streams are rejected for every input and output path.
    A single-instance mutex blocks concurrent scrubs.
#>
#requires -Version 7.0

[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Scrub')]
    [string]$Mode = 'Audit',

    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),

    [string]$ReportPath = (Join-Path $env:LOCALAPPDATA 'Context7StateScrub\context7-scrub-report.json'),

    [string]$RipgrepPath = '',

    [ValidateRange(30, 3600)]
    [int]$ScanTimeoutSeconds = 900,

    [switch]$CloseAndRelaunchCodex,

    [ValidateRange(0, 60)]
    [int]$StartDelaySeconds = 0,

    [ValidateRange(5, 120)]
    [int]$GraceSeconds = 45
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Fingerprint {
    param([Parameter(Mandatory)][string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 12).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Read-SharedText {
    param([Parameter(Mandatory)][string]$Path)

    $sharing = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.FileStream]::new(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        $sharing
    )
    try {
        $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $reader = [System.IO.StreamReader]::new($stream, $strictUtf8, $true)
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-ValidJsonText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][bool]$JsonLines
    )

    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.AllowTrailingCommas = $false
    $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
    $options.MaxDepth = 256

    if ($JsonLines) {
        $lineNumber = 0
        foreach ($line in ($Text -split "`r?`n")) {
            $lineNumber++
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            try {
                $document = [System.Text.Json.JsonDocument]::Parse($line, $options)
                $document.Dispose()
            }
            catch {
                throw "Invalid JSONL at line $lineNumber."
            }
        }
        return
    }

    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Text, $options)
        $document.Dispose()
    }
    catch {
        throw 'Invalid JSON document.'
    }
}

function Assert-NoReparsePointAncestry {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Description path is empty."
    }

    if ($IsWindows) {
        # Device namespaces and UNC paths have multiple spellings for the same
        # filesystem object.  Keep both trusted roots and output paths on an
        # unambiguous, fully qualified local drive path before comparing them.
        if ($Path -match '^[\\/]{2}') {
            throw "$Description path may not use a device namespace or UNC path."
        }
        if (-not [System.IO.Path]::IsPathFullyQualified($Path)) {
            throw "$Description path must be a fully qualified local drive path."
        }

        foreach ($rawComponent in ($Path -split '[\\/]' | Where-Object { -not [string]::IsNullOrEmpty($_) })) {
            if ($rawComponent -eq '.' -or $rawComponent -eq '..' -or $rawComponent -match '^[A-Za-z]:$') {
                continue
            }
            if ($rawComponent.EndsWith('.') -or $rawComponent.EndsWith(' ')) {
                throw "$Description path may not contain components with trailing dots or spaces."
            }
        }
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($pathRoot)) {
        throw "$Description path has no filesystem root."
    }
    if ($IsWindows) {
        if ($pathRoot -notmatch '^[A-Za-z]:[\\/]$') {
            throw "$Description path must use a local drive root."
        }
        if ($fullPath.IndexOf(':', 2) -ge 0) {
            throw "$Description path may not use an alternate data stream."
        }
    }

    $rootItem = Get-Item -LiteralPath $pathRoot -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description path may not have reparse-point ancestry."
    }

    # FileSystemInfo.FullName expands DOS short-name aliases for existing
    # components.  Rebuild any nonexistent suffix from the last physically
    # resolved ancestor so containment checks cannot be bypassed with 8.3
    # spellings while still permitting a new report filename.
    $currentPath = $rootItem.FullName
    $missingAncestor = $false
    $relativePath = $fullPath.Substring($pathRoot.Length)
    foreach ($component in ($relativePath -split '[\\/]' | Where-Object { -not [string]::IsNullOrEmpty($_) })) {
        $candidatePath = Join-Path $currentPath $component
        if ($missingAncestor -or -not (Test-Path -LiteralPath $candidatePath)) {
            $missingAncestor = $true
            $currentPath = $candidatePath
            continue
        }
        $item = Get-Item -LiteralPath $candidatePath -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description path may not have reparse-point ancestry."
        }
        $currentPath = $item.FullName
    }

    return [System.IO.Path]::GetFullPath($currentPath)
}

function Get-SafeRolloutFiles {
    param([Parameter(Mandatory)][string]$Directory)

    $resolvedDirectory = Assert-NoReparsePointAncestry `
        -Path $Directory `
        -Description 'A Context7 rollout directory'
    if (-not (Test-Path -LiteralPath $resolvedDirectory -PathType Container)) {
        return @()
    }

    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($resolvedDirectory)
    while ($pending.Count -gt 0) {
        $currentDirectory = $pending.Pop()
        $null = Assert-NoReparsePointAncestry `
            -Path $currentDirectory `
            -Description 'A Context7 rollout directory'
        foreach ($entry in (Get-ChildItem -LiteralPath $currentDirectory -Force)) {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'A Context7 rollout tree may not contain a reparse point.'
            }
            if ($entry.PSIsContainer) {
                $pending.Push($entry.FullName)
                continue
            }
            if ($entry.Name -like 'rollout-*.jsonl') {
                $null = Assert-NoReparsePointAncestry `
                    -Path $entry.FullName `
                    -Description 'A Context7 rollout target'
                $files.Add($entry)
            }
        }
    }

    return @($files | Sort-Object -Property FullName -Unique)
}

function Get-TargetFiles {
    param([Parameter(Mandatory)][string]$Root)

    $Root = Assert-NoReparsePointAncestry -Path $Root -Description 'The Codex home'
    $targets = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($name in @('.codex-global-state.json', '.codex-global-state.json.bak')) {
        $path = Join-Path $Root $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $null = Assert-NoReparsePointAncestry `
                -Path $path `
                -Description 'A Context7 state target'
            $item = Get-Item -LiteralPath $path
            $targets.Add($item)
        }
    }

    foreach ($directoryName in @('sessions', 'archived_sessions')) {
        $directory = Join-Path $Root $directoryName
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            continue
        }
        foreach ($file in (Get-SafeRolloutFiles -Directory $directory)) {
            $targets.Add($file)
        }
    }

    return @($targets | Sort-Object -Property FullName -Unique)
}

function Get-AffectedRolloutFiles {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RipgrepPath,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $Root = Assert-NoReparsePointAncestry -Path $Root -Description 'The Codex home'
    if (-not (Test-Path -LiteralPath $RipgrepPath -PathType Leaf)) {
        throw 'ripgrep is required for the count-only Context7 scan.'
    }

    $affected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($directoryName in @('sessions', 'archived_sessions')) {
        $directory = Join-Path $Root $directoryName
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            continue
        }
        $null = @(Get-SafeRolloutFiles -Directory $directory)

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $RipgrepPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @(
                '--no-config',
                '--files-with-matches',
                '--null',
                '--no-messages',
                '--no-ignore',
                '--hidden',
                '--glob',
                'rollout-*.jsonl',
                '--',
                $Pattern,
                $directory
            )) {
            $startInfo.ArgumentList.Add($argument)
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            if (-not $process.Start()) {
                throw 'ripgrep did not start.'
            }
            $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
            $standardErrorTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                try {
                    $process.Kill($true)
                    $null = $process.WaitForExit(5000)
                }
                catch {
                    # Preserve the bounded timeout even if process-tree termination races with exit.
                }
                throw 'ripgrep exceeded the Context7 scan timeout.'
            }
            $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
            $null = $standardErrorTask.GetAwaiter().GetResult()
            if ($process.ExitCode -notin @(0, 1)) {
                throw 'ripgrep failed during the count-only Context7 scan.'
            }
        }
        finally {
            $process.Dispose()
        }

        $allowedRoot = [System.IO.Path]::GetFullPath($directory).TrimEnd('\') + '\'
        foreach ($entry in ($standardOutput -split "`0")) {
            if ([string]::IsNullOrWhiteSpace($entry)) {
                continue
            }
            $fullPath = [System.IO.Path]::GetFullPath($entry)
            if (-not $fullPath.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'ripgrep returned a path outside the Codex rollout root.'
            }
            $null = Assert-NoReparsePointAncestry `
                -Path $fullPath `
                -Description 'An identified Context7 rollout target'
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                throw 'An identified rollout file disappeared during the scan.'
            }
            $item = Get-Item -LiteralPath $fullPath
            $null = $affected.Add($fullPath)
        }
    }

    return @($affected | Sort-Object)
}

function Add-SecretsFromText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][regex]$Pattern,
        [Parameter(Mandatory)][System.Collections.Generic.Dictionary[string, string]]$Secrets
    )

    $count = 0
    foreach ($match in $Pattern.Matches($Text)) {
        $count++
        if (-not $Secrets.ContainsKey($match.Value)) {
            $Secrets.Add($match.Value, (Get-Fingerprint -Value $match.Value))
        }
    }
    return $count
}

function Inspect-JsonLinesFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][regex]$Pattern,
        [Parameter(Mandatory)][System.Collections.Generic.Dictionary[string, string]]$Secrets
    )

    $sharing = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $sharing)
    try {
        $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $reader = [System.IO.StreamReader]::new($stream, $strictUtf8, $true)
        try {
            $lineNumber = 0
            $occurrences = 0
            while (($line = $reader.ReadLine()) -ne $null) {
                $lineNumber++
                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }
                try {
                    Assert-ValidJsonText -Text $line -JsonLines $false
                }
                catch {
                    throw "Invalid JSONL at line $lineNumber."
                }
                $occurrences += Add-SecretsFromText -Text $line -Pattern $Pattern -Secrets $Secrets
            }
            return $occurrences
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-ValidJsonLinesFile {
    param([Parameter(Mandatory)][string]$Path)

    $sharing = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $sharing)
    try {
        $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $reader = [System.IO.StreamReader]::new($stream, $strictUtf8, $true)
        try {
            $lineNumber = 0
            while (($line = $reader.ReadLine()) -ne $null) {
                $lineNumber++
                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }
                try {
                    Assert-ValidJsonText -Text $line -JsonLines $false
                }
                catch {
                    throw "Invalid JSONL at line $lineNumber."
                }
            }
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-LineEndingMetadata {
    param([Parameter(Mandatory)][string]$Path)

    $sharing = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $sharing)
    try {
        $bufferLength = [int][Math]::Min(65536, [Math]::Max(1, $stream.Length))
        $buffer = [byte[]]::new($bufferLength)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $newLine = "`n"
        for ($index = 0; $index -lt $read; $index++) {
            if ($buffer[$index] -eq 10) {
                if ($index -gt 0 -and $buffer[$index - 1] -eq 13) {
                    $newLine = "`r`n"
                }
                break
            }
            if ($buffer[$index] -eq 13) {
                if ($index + 1 -lt $read -and $buffer[$index + 1] -eq 10) {
                    $newLine = "`r`n"
                }
                else {
                    $newLine = "`r"
                }
                break
            }
        }
        $hasBom = $read -ge 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF
        $endsWithNewLine = $false
        if ($stream.Length -gt 0) {
            $null = $stream.Seek(-1, [System.IO.SeekOrigin]::End)
            $lastByte = $stream.ReadByte()
            $endsWithNewLine = $lastByte -in @(10, 13)
        }
        return [pscustomobject]@{
            NewLine         = $newLine
            HasBom          = $hasBom
            EndsWithNewLine = $endsWithNewLine
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Initialize-AtomicFileType {
    if ('Context7AtomicFile' -as [type]) {
        return
    }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class Context7AtomicFile
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool MoveFileEx(string existingPath, string newPath, int flags);
}
'@
}

function Complete-AtomicReplacement {
    param(
        [Parameter(Mandatory)][string]$TemporaryPath,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Security.AccessControl.FileSecurity]$Acl,
        [Parameter(Mandatory)][System.IO.FileAttributes]$Attributes,
        [Parameter(Mandatory)][datetime]$LastWriteTimeUtc
    )

    Initialize-AtomicFileType
    Set-Acl -LiteralPath $TemporaryPath -AclObject $Acl
    [System.IO.File]::SetLastWriteTimeUtc($TemporaryPath, $LastWriteTimeUtc)
    [System.IO.File]::SetAttributes($TemporaryPath, $Attributes)

    $destinationAttributes = [System.IO.File]::GetAttributes($Path)
    $destinationWasReadOnly = ($destinationAttributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0
    $replacementSucceeded = $false
    $replaceExistingAndWriteThrough = 0x1 -bor 0x8
    try {
        if ($destinationWasReadOnly) {
            $writableAttributes = [System.IO.FileAttributes](
                [int]$destinationAttributes -band (-bnot [int][System.IO.FileAttributes]::ReadOnly)
            )
            [System.IO.File]::SetAttributes($Path, $writableAttributes)
        }
        if (-not [Context7AtomicFile]::MoveFileEx($TemporaryPath, $Path, $replaceExistingAndWriteThrough)) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Atomic replacement failed with Win32 error $errorCode."
        }
        $replacementSucceeded = $true
    }
    finally {
        if (-not $replacementSucceeded -and $destinationWasReadOnly -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            [System.IO.File]::SetAttributes($Path, $destinationAttributes)
        }
    }
}

function Write-AtomicUtf8File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$ExpectedSourceText,
        [Parameter(Mandatory)][bool]$WriteBom,
        [Parameter(Mandatory)][System.Security.AccessControl.FileSecurity]$Acl,
        [Parameter(Mandatory)][System.IO.FileAttributes]$Attributes,
        [Parameter(Mandatory)][datetime]$LastWriteTimeUtc
    )

    $directory = Split-Path -Parent $Path
    $temporaryPath = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $encoding = [System.Text.UTF8Encoding]::new($WriteBom, $true)
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Text, $encoding)
        $currentSourceText = Read-SharedText -Path $Path
        if ($currentSourceText -cne $ExpectedSourceText) {
            throw 'A Context7 state file changed before its atomic replacement.'
        }
        Complete-AtomicReplacement `
            -TemporaryPath $temporaryPath `
            -Path $Path `
            -Acl $Acl `
            -Attributes $Attributes `
            -LastWriteTimeUtc $LastWriteTimeUtc
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Write-AtomicJsonLinesFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.Generic.Dictionary[string, string]]$Secrets,
        [Parameter(Mandatory)][System.Security.AccessControl.FileSecurity]$Acl,
        [Parameter(Mandatory)][System.IO.FileAttributes]$Attributes,
        [Parameter(Mandatory)][datetime]$LastWriteTimeUtc
    )

    $metadata = Get-LineEndingMetadata -Path $Path
    $directory = Split-Path -Parent $Path
    $temporaryPath = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $sharing = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $initialItem = Get-Item -LiteralPath $Path
    $initialLength = $initialItem.Length
    $initialLastWriteTimeUtc = $initialItem.LastWriteTimeUtc
    $source = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $sharing)
    $reader = $null
    $target = $null
    $writer = $null
    $replacements = 0
    try {
        $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $reader = [System.IO.StreamReader]::new($source, $strictUtf8, $true)
        $encoding = [System.Text.UTF8Encoding]::new($metadata.HasBom)
        $target = [System.IO.FileStream]::new($temporaryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $writer = [System.IO.StreamWriter]::new($target, $encoding)
            try {
                $firstLine = $true
                $lineNumber = 0
                while (($line = $reader.ReadLine()) -ne $null) {
                    $lineNumber++
                    $replacement = $line
                    foreach ($secret in $Secrets.Keys) {
                        $count = ([regex]::Matches($replacement, [regex]::Escape($secret))).Count
                        if ($count -gt 0) {
                            $replacements += $count
                            $replacement = $replacement.Replace($secret, ('[REDACTED_CONTEXT7_KEY:{0}]' -f $Secrets[$secret]))
                        }
                    }
                    if (-not [string]::IsNullOrWhiteSpace($replacement)) {
                        try {
                            Assert-ValidJsonText -Text $replacement -JsonLines $false
                        }
                        catch {
                            throw "Replacement produced invalid JSONL at line $lineNumber."
                        }
                    }
                    if (-not $firstLine) {
                        $writer.Write($metadata.NewLine)
                    }
                    $writer.Write($replacement)
                    $firstLine = $false
                }
                if ($metadata.EndsWithNewLine) {
                    $writer.Write($metadata.NewLine)
                }
                $writer.Flush()
            }
            finally {
                if ($null -ne $writer) {
                    $writer.Dispose()
                }
            }
        }
        finally {
            if ($null -ne $reader) {
                $reader.Dispose()
            }
            if ($null -ne $target) {
                $target.Dispose()
            }
        }

        $currentItem = Get-Item -LiteralPath $Path
        if ($currentItem.Length -ne $initialLength -or $currentItem.LastWriteTimeUtc -ne $initialLastWriteTimeUtc) {
            throw 'A Context7 rollout changed during its replacement pass.'
        }

        Complete-AtomicReplacement `
            -TemporaryPath $temporaryPath `
            -Path $Path `
            -Acl $Acl `
            -Attributes $Attributes `
            -LastWriteTimeUtc $LastWriteTimeUtc
        return $replacements
    }
    finally {
        $source.Dispose()
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Write-SafeReport {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Report,
        [Parameter(Mandatory)][string]$Path
    )

    $Path = Assert-NoReparsePointAncestry -Path $Path -Description 'The Context7 report'
    $directory = Split-Path -Parent $Path
    $null = Assert-NoReparsePointAncestry `
        -Path $directory `
        -Description 'The Context7 report directory'
    if (-not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    $null = Assert-NoReparsePointAncestry `
        -Path $directory `
        -Description 'The Context7 report directory'
    $temporaryPath = Join-Path $directory ('.context7-scrub-report.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Report | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
        $null = Assert-NoReparsePointAncestry `
            -Path $Path `
            -Description 'The Context7 report'
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-CodexGuiProcesses {
    $codexProcesses = @(Get-Process -Name 'Codex' -ErrorAction SilentlyContinue)
    return @($codexProcesses | Where-Object {
            $_.ProcessName -eq 'Codex' -and $_.MainWindowHandle -ne 0
        })
}

function Invoke-CodexRelaunchIfNeeded {
    param([Parameter(Mandatory)][string]$Path)

    if (@(Get-CodexGuiProcesses).Count -eq 0 -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Start-Process -FilePath $Path | Out-Null
    }
}

if ($CloseAndRelaunchCodex -and $Mode -ne 'Scrub') {
    throw '-CloseAndRelaunchCodex is valid only with -Mode Scrub.'
}

$relaunchPath = $null
$relaunchAfterClose = $false
$reportPathIsSafe = $false
$instanceMutex = $null
$instanceMutexOwned = $false
$report = [ordered]@{
    Success              = $false
    Mode                 = $Mode
    TimestampUtc         = [datetime]::UtcNow.ToString('o')
    CandidateFiles       = 0
    AffectedFiles        = 0
    OccurrencesFound     = 0
    OccurrencesRemoved   = 0
    RemainingOccurrences = $null
    DistinctFingerprints = 0
    Fingerprints         = @()
}

try {
    $instanceMutex = [System.Threading.Mutex]::new($false, 'Local\Context7StateScrub')
    try {
        $instanceMutexOwned = $instanceMutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $instanceMutexOwned = $true
    }
    if (-not $instanceMutexOwned) {
        throw 'Another Context7 state scrub is already running.'
    }

    if ($StartDelaySeconds -gt 0) {
        Start-Sleep -Seconds $StartDelaySeconds
    }

    if (-not (Test-Path -LiteralPath $CodexHome -PathType Container)) {
        throw 'Codex home does not exist.'
    }

    $CodexHome = Assert-NoReparsePointAncestry -Path $CodexHome -Description 'The Codex home'
    $ReportPath = Assert-NoReparsePointAncestry -Path $ReportPath -Description 'The Context7 report'
    $resolvedCodexHome = $CodexHome.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    $resolvedReportPath = $ReportPath
    if ($resolvedReportPath.StartsWith($resolvedCodexHome, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The scrub report must be stored outside the Codex state directory.'
    }
    $reportPathIsSafe = $true

    if ([string]::IsNullOrWhiteSpace($RipgrepPath)) {
        $ripgrepCommand = Get-Command rg -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $RipgrepPath = $ripgrepCommand.Source
    }
    if (-not (Test-Path -LiteralPath $RipgrepPath -PathType Leaf)) {
        throw 'ripgrep is required for the count-only Context7 scan.'
    }

    $keyPattern = [regex]'ctx7sk-[A-Za-z0-9_-]{16,}'

    if ($CloseAndRelaunchCodex) {
        $guiProcesses = @(Get-CodexGuiProcesses)
        if ($guiProcesses.Count -eq 0) {
            throw 'No running Codex GUI was found for the offline scrub.'
        }

        $relaunchPath = $guiProcesses[0].Path
        if ([string]::IsNullOrWhiteSpace($relaunchPath)) {
            throw 'The Codex relaunch path could not be resolved.'
        }
        $relaunchAfterClose = $true
        foreach ($process in $guiProcesses) {
            if (-not $process.CloseMainWindow()) {
                throw 'Codex did not accept a graceful close request.'
            }
        }

        $deadline = [datetime]::UtcNow.AddSeconds($GraceSeconds)
        do {
            $remaining = @(Get-Process -Name 'Codex' -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) {
                break
            }
            Start-Sleep -Milliseconds 250
        } while ([datetime]::UtcNow -lt $deadline)

        if ($remaining.Count -gt 0) {
            throw 'Codex did not close within the grace period.'
        }
        Start-Sleep -Milliseconds 1500
    }

    $records = [System.Collections.Generic.List[object]]::new()
    $secrets = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)

    $targetFiles = @(Get-TargetFiles -Root $CodexHome)
    $report.CandidateFiles = $targetFiles.Count

    foreach ($file in @($targetFiles | Where-Object { $_.Extension -eq '.jsonl' })) {
        Assert-ValidJsonLinesFile -Path $file.FullName
    }

    foreach ($file in @($targetFiles | Where-Object { $_.Extension -ne '.jsonl' })) {
        $text = Read-SharedText -Path $file.FullName
        Assert-ValidJsonText -Text $text -JsonLines $false
        $occurrences = Add-SecretsFromText -Text $text -Pattern $keyPattern -Secrets $secrets
        $records.Add([pscustomobject]@{
                Path             = $file.FullName
                Text             = $text
                JsonLines        = $false
                Occurrences      = $occurrences
                HasBom           = (Get-LineEndingMetadata -Path $file.FullName).HasBom
                Acl              = Get-Acl -LiteralPath $file.FullName
                Attributes       = $file.Attributes
                LastWriteTimeUtc = $file.LastWriteTimeUtc
            })
    }

    $affectedRollouts = @(Get-AffectedRolloutFiles `
            -Root $CodexHome `
            -RipgrepPath $RipgrepPath `
            -Pattern $keyPattern.ToString() `
            -TimeoutSeconds $ScanTimeoutSeconds)
    foreach ($path in $affectedRollouts) {
        $file = Get-Item -LiteralPath $path
        $occurrences = Inspect-JsonLinesFile -Path $path -Pattern $keyPattern -Secrets $secrets
        if ($occurrences -eq 0) {
            throw 'A rollout changed while the Context7 scan was in progress.'
        }
        $records.Add([pscustomobject]@{
                Path             = $path
                Text             = $null
                JsonLines        = $true
                Occurrences      = $occurrences
                Acl              = Get-Acl -LiteralPath $path
                Attributes       = $file.Attributes
                LastWriteTimeUtc = $file.LastWriteTimeUtc
            })
    }

    $fingerprints = @($secrets.Values | Sort-Object -Unique)
    $report.DistinctFingerprints = $fingerprints.Count
    $report.Fingerprints = $fingerprints

    foreach ($record in $records) {
        if ($record.Occurrences -gt 0) {
            $report.AffectedFiles++
            $report.OccurrencesFound += $record.Occurrences
        }
    }

    if ($Mode -eq 'Scrub') {
        foreach ($record in @($records | Where-Object { $_.Occurrences -gt 0 })) {
            if ($record.JsonLines) {
                $replaced = Write-AtomicJsonLinesFile `
                    -Path $record.Path `
                    -Secrets $secrets `
                    -Acl $record.Acl `
                    -Attributes $record.Attributes `
                    -LastWriteTimeUtc $record.LastWriteTimeUtc
                if ($replaced -ne $record.Occurrences) {
                    throw 'A rollout changed before its atomic replacement.'
                }
                $report.OccurrencesRemoved += $replaced
                continue
            }

            $replacement = $record.Text
            foreach ($secret in $secrets.Keys) {
                $replacement = $replacement.Replace(
                    $secret,
                    ('[REDACTED_CONTEXT7_KEY:{0}]' -f $secrets[$secret])
                )
            }
            Assert-ValidJsonText -Text $replacement -JsonLines $false
            Write-AtomicUtf8File `
                -Path $record.Path `
                -Text $replacement `
                -ExpectedSourceText $record.Text `
                -WriteBom $record.HasBom `
                -Acl $record.Acl `
                -Attributes $record.Attributes `
                -LastWriteTimeUtc $record.LastWriteTimeUtc
            $report.OccurrencesRemoved += $record.Occurrences
        }

        $remaining = 0
        foreach ($file in @(Get-TargetFiles -Root $CodexHome | Where-Object { $_.Extension -ne '.jsonl' })) {
            $text = Read-SharedText -Path $file.FullName
            Assert-ValidJsonText -Text $text -JsonLines $false
            $remaining += $keyPattern.Matches($text).Count
        }
        $verificationSecrets = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
        foreach ($path in @(Get-AffectedRolloutFiles `
                    -Root $CodexHome `
                    -RipgrepPath $RipgrepPath `
                    -Pattern $keyPattern.ToString() `
                    -TimeoutSeconds $ScanTimeoutSeconds)) {
            $remaining += Inspect-JsonLinesFile -Path $path -Pattern $keyPattern -Secrets $verificationSecrets
        }
        $report.RemainingOccurrences = $remaining
        if ($remaining -ne 0) {
            throw 'Context7 key material remains after the scrub.'
        }
    }

    $report.Success = $true
    Write-SafeReport -Report $report -Path $ReportPath
    [pscustomobject]$report
}
catch {
    $report.ErrorType = $_.Exception.GetType().FullName
    if ($reportPathIsSafe) {
        Write-SafeReport -Report $report -Path $ReportPath
    }
    throw
}
finally {
    if ($instanceMutexOwned -and $null -ne $instanceMutex) {
        $instanceMutex.ReleaseMutex()
    }
    if ($null -ne $instanceMutex) {
        $instanceMutex.Dispose()
    }
    if ($relaunchAfterClose -and -not [string]::IsNullOrEmpty($relaunchPath)) {
        Invoke-CodexRelaunchIfNeeded -Path $relaunchPath
    }
}
