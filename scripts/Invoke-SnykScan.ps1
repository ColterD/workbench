<#
.SYNOPSIS
    Reusable Snyk gate for a project: dependency scan, SAST, and container
    scan, chosen from the project layout. Exits nonzero on findings at or
    above the severity threshold, and fail-closed (exit 2) on scan errors or
    misconfiguration. Idempotent, keeps no state, never echoes the token.
.PARAMETER ProjectPath
    Project directory to scan.
.PARAMETER SeverityThreshold
    Minimum severity that fails the gate: low, medium, high (default), critical.
.PARAMETER ContainerImage
    Existing image to container-scan. When omitted and a Dockerfile exists,
    a local '<dirname>:local' image is built (requires docker CLI).
.PARAMETER SkipCode
    Skip 'snyk code test' (SAST).
.PARAMETER SkipContainer
    Skip the container scan even when a Dockerfile is present.
.EXAMPLE
    pwsh -File Invoke-SnykScan.ps1 -ProjectPath D:\Projects\screenarr
.EXAMPLE
    pwsh -File Invoke-SnykScan.ps1 -ProjectPath . -SeverityThreshold critical -SkipContainer
.NOTES
    Exit codes: 0 = clean, 1 = findings at/above threshold, 2 = scan failed
    or misconfigured (missing CLI, missing SNYK_TOKEN, snyk/docker error).
    SNYK_TOKEN is read from the process env, falling back to the USER-level
    env var. It is never printed, logged, or written anywhere by this script.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [ValidateSet('low', 'medium', 'high', 'critical')][string]$SeverityThreshold = 'high',
    [string]$ContainerImage,
    [switch]$SkipCode,
    [switch]$SkipContainer
)

$ErrorActionPreference = 'Stop'
$scanRoot = (Resolve-Path -LiteralPath $ProjectPath).Path

function Stop-Misconfig([string]$Message) {
    [Console]::Error.WriteLine("snyk scan misconfigured: $Message")
    exit 2
}

# --- Snyk CLI ---
$snykExe = Get-Command snyk -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
if (-not $snykExe) {
    Stop-Misconfig "Snyk CLI not found. Install: winget install --id Snyk.Snyk --exact (or npm install -g snyk). See docs/snyk.md."
}

# --- Token (process env, else user-level; never echoed) ---
if ([string]::IsNullOrWhiteSpace($env:SNYK_TOKEN)) {
    $userToken = [Environment]::GetEnvironmentVariable('SNYK_TOKEN', 'User')
    if ([string]::IsNullOrWhiteSpace($userToken)) {
        Stop-Misconfig "SNYK_TOKEN is not set. Set it as a USER-level environment variable only — never in any file. See docs/snyk.md."
    }
    $env:SNYK_TOKEN = $userToken
}

# --- Which scan types fit this layout? ---
$depManifests = @(
    'package.json', 'pyproject.toml', 'requirements.txt', 'Pipfile',
    'pom.xml', 'build.gradle', 'build.gradle.kts', 'go.mod',
    'Gemfile', 'composer.json'
)
$hasDeps = [bool]($depManifests | Where-Object { Test-Path (Join-Path $scanRoot $_) } | Select-Object -First 1)
if (-not $hasDeps) {
    $hasDeps = [bool](Get-ChildItem -Path $scanRoot -Filter *.csproj -File -ErrorAction SilentlyContinue)
}
$dockerfilePath = Join-Path $scanRoot 'Dockerfile'

$failures = [Collections.Generic.List[string]]::new()
$findings = [Collections.Generic.List[string]]::new()

Push-Location $scanRoot
try {
    if ($hasDeps) {
        Write-Host "==> snyk test (dependencies, threshold $SeverityThreshold)" -ForegroundColor Cyan
        & $snykExe test "--severity-threshold=$SeverityThreshold"
        $code = $LASTEXITCODE
        if ($code -eq 1) { $findings.Add('dependencies') } elseif ($code -ne 0) { $failures.Add("snyk test exited $code") }
    } else {
        Write-Host "==> no dependency manifest; dependency scan skipped"
    }

    if (-not $SkipCode) {
        Write-Host "==> snyk code test (SAST, threshold $SeverityThreshold)" -ForegroundColor Cyan
        & $snykExe code test "--severity-threshold=$SeverityThreshold"
        $code = $LASTEXITCODE
        if ($code -eq 1) { $findings.Add('code') } elseif ($code -ne 0) { $failures.Add("snyk code test exited $code") }
    }

    if ((Test-Path $dockerfilePath) -and -not $SkipContainer) {
        $image = $ContainerImage
        if (-not $image) {
            if (Get-Command docker -ErrorAction SilentlyContinue) {
                $image = "$(Split-Path -Leaf $scanRoot):local"
                Write-Host "==> docker build -t $image (for container scan)" -ForegroundColor Cyan
                docker build -q -t $image . | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    $failures.Add("docker build exited $LASTEXITCODE")
                    $image = $null
                }
            } else {
                Write-Host "==> docker CLI unavailable; container scan skipped"
            }
        }
        if ($image) {
            Write-Host "==> snyk container test $image (threshold $SeverityThreshold)" -ForegroundColor Cyan
            & $snykExe container test $image "--file=$dockerfilePath" "--severity-threshold=$SeverityThreshold"
            $code = $LASTEXITCODE
            if ($code -eq 1) { $findings.Add('container') } elseif ($code -ne 0) { $failures.Add("snyk container test exited $code") }
        }
    }
} finally { Pop-Location }

if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("snyk scan FAILED (fail closed):")
    $failures | ForEach-Object { [Console]::Error.WriteLine("  $_") }
    exit 2
}
if ($findings.Count -gt 0) {
    [Console]::Error.WriteLine("snyk found issues at/above '$SeverityThreshold' in: $($findings -join ', ')")
    exit 1
}
Write-Host "snyk scan clean (threshold $SeverityThreshold)." -ForegroundColor Green
exit 0
