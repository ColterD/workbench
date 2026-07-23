<#
.SYNOPSIS
    Pattern-based secret scan for a project directory. Scans tracked files,
    untracked-non-ignored files, and staged content when inside a git repo.
    Exits 1 on any hit. Optional allowlist: <root>\.secret-scan-allow
    (one literal allowed value per line).
.EXAMPLE
    pwsh -File Invoke-SecretScan.ps1 -Path D:\Projects\screenarr
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $Path).Path

$patterns = @(
    '(?i)(api[_-]?key|secret|password|passwd|token)\s*[=:]\s*["'']?[A-Za-z0-9._~+/=-]{16,}',
    'ghp_[A-Za-z0-9]{20,}',
    'github_pat_[A-Za-z0-9_]{20,}',
    'sk-[A-Za-z0-9]{20,}',
    'snyk_uat\.[A-Za-z0-9._-]{20,}',
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',
    '(?i)bearer\s+[A-Za-z0-9._~+/=-]{20,}'
)

$allowlist = @()
$allowFile = Join-Path $root '.secret-scan-allow'
if (Test-Path -LiteralPath $allowFile) {
    $allowlist = @(Get-Content -LiteralPath $allowFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

# Collect candidate files: git-aware when possible, filesystem otherwise.
$files = @()
Push-Location $root
try {
    $isRepo = $null -ne (git rev-parse --show-toplevel 2>$null)
    if ($isRepo) {
        $files = @(git ls-files) + @(git ls-files --others --exclude-standard)
    } else {
        $files = @(Get-ChildItem -Recurse -File | ForEach-Object {
            $_.FullName.Substring($root.Length).TrimStart('\', '/')
        })
    }
} finally { Pop-Location }

$hits = [Collections.Generic.List[string]]::new()
foreach ($relative in ($files | Sort-Object -Unique)) {
    $full = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $text = [IO.File]::ReadAllText($full)
    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($text, $pattern)) {
            $allowed = $false
            foreach ($allowedValue in $allowlist) {
                if ($match.Value.Contains($allowedValue)) { $allowed = $true; break }
            }
            if (-not $allowed) { $hits.Add("${relative}: $($match.Value.Substring(0, [Math]::Min(24, $match.Value.Length)))...") }
        }
    }
}

if ($hits.Count -gt 0) {
    [Console]::Error.WriteLine("secret scan found $($hits.Count) potential hit(s):")
    $hits | ForEach-Object { [Console]::Error.WriteLine("  $_") }
    exit 1
}
Write-Host "secret scan clean ($($files.Count) files)"
exit 0
