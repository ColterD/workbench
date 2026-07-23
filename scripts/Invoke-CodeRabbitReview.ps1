<#
.SYNOPSIS
    Invoke the central quota-aware CodeRabbit runner for a repository's
    uncommitted changes. Requires PowerShell 7 (the runner has #requires 7.2)
    and a task identity (CODERABBIT_TASK_ID) for quota/replay accounting.
.EXAMPLE
    pwsh -File Invoke-CodeRabbitReview.ps1 -Repository D:\Projects\screenarr
.EXAMPLE
    pwsh -File Invoke-CodeRabbitReview.ps1 -Repository . -TaskId "my-feature-review"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [string]$TaskId = "manual-review-$(Get-Date -Format 'yyyy-MM-dd')",
    [string]$Runner = $(if ($env:CODERABBIT_RUNNER) { $env:CODERABBIT_RUNNER } else { 'D:\Projects\coderabbit\Invoke-CodeRabbit.ps1' })
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath $Repository).Path

# The runner requires pwsh 7.2+; re-launch under pwsh if we are on 5.1.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $pwsh) { $pwsh = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe' }
    if (-not (Test-Path $pwsh)) { throw 'PowerShell 7 (pwsh) not found; install via workbench bootstrap.' }
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Repository $repo -TaskId $TaskId -Runner $Runner
    exit $LASTEXITCODE
}

if (-not (Test-Path -LiteralPath $Runner -PathType Leaf)) {
    throw "Central CodeRabbit runner unavailable: $Runner (set CODERABBIT_RUNNER or pass -Runner)"
}

$config = Join-Path $repo '.coderabbit.yaml'
if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
    throw "No .coderabbit.yaml at $repo; the central runner requires a complete config."
}

$env:CODERABBIT_TASK_ID = $TaskId
Write-Host "==> CodeRabbit review: $repo (task '$TaskId')" -ForegroundColor Cyan
& $Runner -Repository $repo -Uncommitted -Config $config
$code = $LASTEXITCODE
switch ($code) {
    0 { Write-Host 'CodeRabbit: clean (or no changes).' -ForegroundColor Green }
    2 { Write-Host 'CodeRabbit: critical/major findings — resolve before committing.' -ForegroundColor Yellow }
    3 { Write-Host 'CodeRabbit: deferred by quota/replay policy; identical diff may already be reviewed.' -ForegroundColor Yellow }
    default { Write-Host "CodeRabbit: review failed (exit $code)." -ForegroundColor Red }
}
exit $code
