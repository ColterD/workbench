<#
.SYNOPSIS
    ASCII gate for source files: exits 1 when any scanned file contains
    non-ASCII characters (bytes outside 0x00-0x7F), listing the offending
    lines. Prevents encoding corruption (smart quotes, mojibake) from
    slipping into source. Read-only and idempotent — safe to re-run.
.PARAMETER Path
    One or more directories to scan, relative to the current location or
    absolute. Missing directories are skipped with a warning. Default: 'src'.
.PARAMETER Extensions
    File extensions to check, without dots. Default: 'ts'.
.PARAMETER MaxLinesPerFile
    Maximum offending lines printed per file (default 10).
.EXAMPLE
    pwsh -File Invoke-AsciiScan.ps1
.EXAMPLE
    pwsh -File Invoke-AsciiScan.ps1 -Path src, scripts -Extensions ts, ps1
.NOTES
    Exit codes: 0 = all scanned files ASCII-clean, 1 = non-ASCII found.
    Standalone optional gate: NOT part of Invoke-PrePublishGate.ps1 — call
    it directly or from CI (see docs/pre-publish-gate.md).
    Bytes are compared via a Latin-1 (1 byte = 1 char) read so multi-byte
    UTF-8 sequences are caught exactly like grep -P '[^\x00-\x7F]'.
#>
[CmdletBinding()]
param(
    [string[]]$Path = @('src'),
    [string[]]$Extensions = @('ts'),
    [ValidateRange(1, 100)][int]$MaxLinesPerFile = 10
)

$ErrorActionPreference = 'Stop'
$latin1 = [System.Text.Encoding]::GetEncoding('ISO-8859-1')

$failures = [Collections.Generic.List[string]]::new()
$scanned = 0

foreach ($dir in $Path) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-Host "==> '$dir' not found; skipped" -ForegroundColor DarkYellow
        continue
    }
    foreach ($ext in $Extensions) {
        $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter "*.$ext")
        foreach ($file in $files) {
            $scanned++
            $text = [System.IO.File]::ReadAllText($file.FullName, $latin1)
            $lineNumber = 0
            $shown = 0
            $fileHeaderPrinted = $false
            foreach ($line in ($text -split "`r?`n")) {
                $lineNumber++
                if ($line -match '[^\x00-\x7F]') {
                    if (-not $fileHeaderPrinted) {
                        $failures.Add($file.FullName)
                        [Console]::Error.WriteLine("ERROR: Non-ASCII characters found in $($file.FullName):")
                        $fileHeaderPrinted = $true
                    }
                    if ($shown -lt $MaxLinesPerFile) {
                        [Console]::Error.WriteLine("  ${lineNumber}: $line")
                        $shown++
                    }
                }
            }
        }
    }
}

if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("ascii scan found non-ASCII in $($failures.Count) file(s):")
    $failures | ForEach-Object { [Console]::Error.WriteLine("  $_") }
    exit 1
}
Write-Host "ascii scan clean ($scanned files)" -ForegroundColor Green
exit 0
