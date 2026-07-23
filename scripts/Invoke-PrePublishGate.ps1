<#
.SYNOPSIS
    Generic pre-publish gate for a project: lint, tests, docker build, secret
    scan. Skips whatever a project does not have. Exits nonzero on failure.
.EXAMPLE
    pwsh -File Invoke-PrePublishGate.ps1 -ProjectPath D:\Projects\screenarr
.EXAMPLE
    pwsh -File Invoke-PrePublishGate.ps1 -ProjectPath . -SkipDocker
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [switch]$SkipDocker,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $ProjectPath).Path
$scriptDir = $PSScriptRoot

function Invoke-Step([string]$Name, [scriptblock]$Action) {
    Write-Host "==> $Name" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE" }
}

Push-Location $root
try {
    Invoke-Step 'secret scan' {
        & (Join-Path $scriptDir 'Invoke-SecretScan.ps1') -Path $root
    }

    if (Test-Path (Join-Path $root 'pyproject.toml')) {
        Invoke-Step 'ruff' { uv run --with ruff python -m ruff check . }
        if (-not $SkipTests) {
            Invoke-Step 'pytest' { uv run --with ruff --with pytest python -m pytest -q }
        }
    } elseif (Test-Path (Join-Path $root 'package.json')) {
        Invoke-Step 'npm tests' { npm test }
    } else {
        Write-Host "==> no recognized project type; lint/tests skipped"
    }

    if ((Test-Path (Join-Path $root 'Dockerfile')) -and -not $SkipDocker) {
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            $tag = "$(Split-Path -Leaf $root):local"
            Invoke-Step 'docker build' { docker build -t $tag . }
        } else {
            Write-Host "==> docker CLI unavailable; build skipped (install via bootstrap)"
        }
    }

    Write-Host "Pre-publish gate passed." -ForegroundColor Green
} finally { Pop-Location }
