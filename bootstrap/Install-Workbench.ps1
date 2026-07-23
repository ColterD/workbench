<#
.SYNOPSIS
    Idempotent workbench bootstrap for a fresh or existing Windows machine.
    Safe to re-run. Ends with a pass/fail/manual checklist.
.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File Install-Workbench.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoInstall   # check only; never install anything
)

$ErrorActionPreference = 'Continue'
$results = [Collections.Generic.List[psobject]]::new()

function Add-Result([string]$Name, [string]$Status, [string]$Detail) {
    $results.Add([pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail })
}

function Install-WithWinget([string]$Id, [string]$Name) {
    # Tri-state: $true = installed this run, $false = install attempted and
    # failed, $null = manual action needed (already recorded as MANUAL).
    # -NoInstall is check-only: report MANUAL, never install, never FAIL.
    if ($NoInstall) { Add-Result $Name 'MANUAL' "not installed; run: winget install $Id"; return $null }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Add-Result $Name 'MANUAL' "winget unavailable; install $Id by hand"; return $null
    }
    winget install --id $Id --exact --silent --accept-source-agreements --accept-package-agreements
    return ($LASTEXITCODE -eq 0)
}

Write-Host "==> workbench bootstrap" -ForegroundColor Cyan

# --- Git ---
if (Get-Command git -ErrorAction SilentlyContinue) {
    Add-Result 'Git' 'PASS' (git --version)
} else {
    $installResult = Install-WithWinget 'Git.Git' 'Git'
    if ($true -eq $installResult) { Add-Result 'Git' 'FIXED' 'installed via winget; restart shell for PATH' }
    elseif ($null -ne $installResult) { Add-Result 'Git' 'FAIL' 'not installed; winget install failed' }
}

# --- PowerShell 7 ---
$pwshPath = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
if (-not $pwshPath) {
    $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    if (Test-Path $candidate) { $pwshPath = $candidate }
}
if ($pwshPath) { Add-Result 'PowerShell 7' 'PASS' $pwshPath }
else {
    $installResult = Install-WithWinget 'Microsoft.PowerShell' 'PowerShell 7'
    if ($true -eq $installResult) { Add-Result 'PowerShell 7' 'FIXED' 'installed via winget' }
    elseif ($null -ne $installResult) { Add-Result 'PowerShell 7' 'FAIL' 'not installed; winget install failed' }
}

# --- uv ---
if (Get-Command uv -ErrorAction SilentlyContinue) {
    Add-Result 'uv' 'PASS' (uv --version)
} else {
    $installResult = Install-WithWinget 'astral-sh.uv' 'uv'
    if ($true -eq $installResult) { Add-Result 'uv' 'FIXED' 'installed via winget; restart shell for PATH' }
    elseif ($null -ne $installResult) { Add-Result 'uv' 'FAIL' 'not installed; winget install failed' }
}

# --- Snyk CLI (winget id Snyk.Snyk verified against the winget source) ---
if (Get-Command snyk -ErrorAction SilentlyContinue) {
    Add-Result 'Snyk CLI' 'PASS' (snyk --version)
} else {
    $installResult = Install-WithWinget 'Snyk.Snyk' 'Snyk CLI'
    if ($true -eq $installResult) { Add-Result 'Snyk CLI' 'FIXED' 'installed via winget; restart shell for PATH' }
    elseif ($null -ne $installResult) { Add-Result 'Snyk CLI' 'FAIL' 'not installed; winget install failed' }
}

# --- Docker: daemon + CLI are separate concerns ---
$daemonUp = [bool](Get-Process 'com.docker.backend', 'dockerd' -ErrorAction SilentlyContinue)
Add-Result 'Docker daemon' ($(if ($daemonUp) { 'PASS' } else { 'MANUAL' })) `
    $(if ($daemonUp) { 'Docker Desktop backend running' } else { 'start Docker Desktop (or install it)' })
if (Get-Command docker -ErrorAction SilentlyContinue) {
    Add-Result 'Docker CLI' 'PASS' (docker --version)
} elseif ($daemonUp -and -not $NoInstall) {
    # Standalone CLI against the running Desktop daemon; no credential helper.
    $binDir = Join-Path $env:LOCALAPPDATA 'Workbench\bin'
    [void][IO.Directory]::CreateDirectory($binDir)
    $dockerExe = Join-Path $binDir 'docker.exe'
    if (-not (Test-Path $dockerExe)) {
        $zip = Join-Path $env:TEMP 'docker-cli.zip'
        Invoke-WebRequest -Uri 'https://download.docker.com/win/static/stable/x86_64/docker-28.3.3.zip' -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath (Join-Path $env:TEMP 'docker-cli-x') -Force
        Copy-Item (Join-Path $env:TEMP 'docker-cli-x\docker\docker.exe') $dockerExe
    }
    $dockerConfig = Join-Path $env:LOCALAPPDATA 'Workbench\docker-config'
    [void][IO.Directory]::CreateDirectory($dockerConfig)
    if (-not (Test-Path (Join-Path $dockerConfig 'config.json'))) { '{}' | Set-Content (Join-Path $dockerConfig 'config.json') }
    [Environment]::SetEnvironmentVariable('DOCKER_CONFIG', $dockerConfig, 'User')
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($userPath -notlike "*$binDir*") { [Environment]::SetEnvironmentVariable('PATH', "$userPath;$binDir", 'User') }
    Add-Result 'Docker CLI' 'FIXED' "standalone CLI at $dockerExe (PATH+DOCKER_CONFIG set at user level; restart shell)"
} else { Add-Result 'Docker CLI' 'MANUAL' 'no CLI on PATH' }

# --- WSL Debian ---
$wslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'
if (Test-Path $wslExe) {
    $distros = (& $wslExe -l -q 2>$null) -replace "`0", ''
    if ($distros -match 'Debian') { Add-Result 'WSL Debian' 'PASS' 'distribution present' }
    else { Add-Result 'WSL Debian' 'MANUAL' 'run: wsl --install -d Debian (reboot required)' }
} else { Add-Result 'WSL Debian' 'MANUAL' 'WSL not installed; run: wsl --install -d Debian' }

# --- Pester (for PowerShell test suites) ---
$pesterOk = & $pwshPath -NoProfile -Command "(Get-Module -ListAvailable Pester | Select-Object -First 1).Version -ne `$null" 2>$null
if ($pesterOk -match 'True') { Add-Result 'Pester' 'PASS' 'module present' }
elseif ($pwshPath -and -not $NoInstall) {
    & $pwshPath -NoProfile -Command "Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion 5.7.0 -MaximumVersion 5.99.99"
    Add-Result 'Pester' 'FIXED' 'installed for current user (5.x)'
} else { Add-Result 'Pester' 'MANUAL' 'Install-Module Pester -Scope CurrentUser' }

# --- User-level environment variables (names only, never secrets) ---
$envDefaults = @{
    CODERABBIT_RUNNER = 'D:\Projects\coderabbit\Invoke-CodeRabbit.ps1'
}
foreach ($name in $envDefaults.Keys) {
    $current = [Environment]::GetEnvironmentVariable($name, 'User')
    if ([string]::IsNullOrWhiteSpace($current)) {
        if ($NoInstall) {
            Add-Result "env:$name" 'MANUAL' "not set; re-run without -NoInstall to apply the default"
            continue
        }
        [Environment]::SetEnvironmentVariable($name, $envDefaults[$name], 'User')
        Add-Result "env:$name" 'FIXED' "set to $($envDefaults[$name])"
    } else { Add-Result "env:$name" 'PASS' $current }
}

# --- SNYK_TOKEN: a secret, so bootstrap only CHECKS presence, never sets it ---
if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('SNYK_TOKEN', 'User'))) {
    Add-Result 'env:SNYK_TOKEN' 'MANUAL' 'set as user-level env var only; see docs/snyk.md'
} else { Add-Result 'env:SNYK_TOKEN' 'PASS' 'user-level env var present' }

# --- Shell profiles + git config (copy if different; back up existing once) ---
$workbenchRoot = Split-Path -Parent $PSScriptRoot
$profileTargets = @(
    @{ Source = 'shell\Microsoft.PowerShell_profile.ps1'; Target = (& $pwshPath -NoProfile -Command 'Write-Host $PROFILE' 2>$null) },
    @{ Source = 'shell\.bashrc'; Target = (Join-Path $env:USERPROFILE '.bashrc') },
    @{ Source = 'git\.gitconfig'; Target = (Join-Path $env:USERPROFILE '.gitconfig') },
    @{ Source = 'git\.gitignore-global'; Target = (Join-Path $env:USERPROFILE '.gitignore-global') }
)
foreach ($item in $profileTargets) {
    $src = Join-Path $workbenchRoot $item.Source
    if (-not (Test-Path $src) -or [string]::IsNullOrWhiteSpace($item.Target)) { continue }
    $leaf = Split-Path -Leaf $item.Target
    if ((Test-Path $item.Target) -and ((Get-FileHash $src).Hash -eq (Get-FileHash $item.Target).Hash)) {
        Add-Result "profile:$leaf" 'PASS' 'already matches workbench copy'; continue
    }
    if ($NoInstall) { Add-Result "profile:$leaf" 'MANUAL' "copy $src -> $($item.Target)"; continue }
    $backedUp = $false
    if (Test-Path $item.Target) {
        $backup = "$($item.Target).pre-workbench"
        if (-not (Test-Path $backup)) { Copy-Item $item.Target $backup }
        $backedUp = $true
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $item.Target))
    Copy-Item $src $item.Target -Force
    $detail = if ($backedUp) { "installed (previous version backed up to $($item.Target).pre-workbench)" } else { 'installed (no previous version)' }
    Add-Result "profile:$leaf" 'FIXED' $detail
}

# --- Checklist ---
Write-Host ""
Write-Host "==> checklist" -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$failed = @($results | Where-Object Status -eq 'FAIL')
$manual = @($results | Where-Object Status -eq 'MANUAL')
Write-Host ("{0} pass, {1} fixed, {2} manual, {3} failed" -f `
    @($results | Where-Object Status -eq 'PASS').Count, `
    @($results | Where-Object Status -eq 'FIXED').Count, `
    $manual.Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
