<#
.SYNOPSIS
    Sync secrets from OpenBao/Vault to Windows user-level environment
    variables, driven by an inventory map (sync-secrets.map.json) that holds
    NAMES AND PATHS ONLY. Values flow vault -> env var, never to disk, logs,
    or console; output reports names and set/mask status only. Idempotent:
    entries already in sync are left untouched.
.PARAMETER Check
    Report-only mode: per-entry SET/MISSING locally, verify-flag warnings,
    vault reachability. Always exits 0.
.PARAMETER MapPath
    Inventory map to use. Defaults to sync-secrets.map.json next to this
    script.
.PARAMETER WhatIf
    Report what apply mode WOULD set without changing anything.
.EXAMPLE
    pwsh -File Sync-Secrets.ps1 -Check
.EXAMPLE
    pwsh -File Sync-Secrets.ps1            # apply: pull and set user env vars
.EXAMPLE
    pwsh -File Sync-Secrets.ps1 -WhatIf
.NOTES
    Exit codes: 0 = applied / in sync / graceful degrade (no VAULT_ADDR,
    vault unreachable, or no token — reported, nothing applied);
    1 = at least one entry failed to apply; 2 = map invalid.
    VAULT_ADDR: process env, falling back to the user-level env var. It is
    local-only and never committed. VAULT_TOKEN: env var only, never
    persisted by this script, never printed, never logged. Prefers the bao
    or vault CLI when present; otherwise plain HTTPS REST (kv-v2).
#>
#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Check,
    [string]$MapPath = (Join-Path $PSScriptRoot 'sync-secrets.map.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-SecretsMap {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Secrets map not found: $Path"
    }
    try {
        $map = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Secrets map is not valid JSON: $Path"
    }
    if ($null -eq $map.PSObject.Properties['entries']) {
        throw "Secrets map has no 'entries' object: $Path"
    }

    $entries = [Collections.Generic.List[psobject]]::new()
    foreach ($property in $map.entries.PSObject.Properties) {
        $name = $property.Name
        $entry = $property.Value
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw 'Secrets map has an entry with an empty env var name.'
        }
        foreach ($field in @('path', 'key')) {
            $fieldProperty = $entry.PSObject.Properties[$field]
            if ($null -eq $fieldProperty -or [string]::IsNullOrWhiteSpace([string]$fieldProperty.Value)) {
                throw "Secrets map entry '$name' is missing a non-empty '$field'."
            }
        }
        $descriptionProperty = $entry.PSObject.Properties['description']
        $entries.Add([pscustomobject]@{
                Name        = $name
                Path        = [string]$entry.PSObject.Properties['path'].Value
                Key         = [string]$entry.PSObject.Properties['key'].Value
                Description = $(if ($null -ne $descriptionProperty) { [string]$descriptionProperty.Value } else { '' })
                Verify      = [bool]($entry.PSObject.Properties['verify'] -and $entry.verify)
            })
    }
    if ($entries.Count -eq 0) {
        throw "Secrets map has no entries: $Path"
    }
    return @($entries | Sort-Object -Property Name)
}

# Thin wrappers around machine state so tests can stub them.
function Get-UserEnvValue([string]$Name) {
    return [Environment]::GetEnvironmentVariable($Name, 'User')
}

function Set-UserEnvValue([string]$Name, [string]$Value) {
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
}

function Test-VaultReachable([string]$Addr) {
    # sys/health needs no token; any HTTP response (even 429/503) means the
    # server is there. Connection failures mean unreachable.
    try {
        $null = Invoke-RestMethod -Method Get -Uri "$($Addr.TrimEnd('/'))/v1/sys/health" `
            -TimeoutSec 5 -SkipHttpErrorCheck
        return $true
    }
    catch {
        return $false
    }
}

function Get-VaultSecretValue {
    param(
        [Parameter(Mandatory)][string]$Addr,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$KvPath,
        [Parameter(Mandatory)][string]$Key
    )

    $mount, $subPath = $KvPath -split '/', 2
    if ([string]::IsNullOrWhiteSpace($mount) -or [string]::IsNullOrWhiteSpace($subPath)) {
        throw "kv path '$KvPath' must include a mount and a secret path (e.g. secret/apps/foo)."
    }

    $bao = Get-Command bao -ErrorAction SilentlyContinue | Select-Object -First 1
    $vault = Get-Command vault -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bao -or $vault) {
        # Child processes inherit this process's env; set the values the CLIs
        # read for the duration of the call (process env is not persistence).
        $env:VAULT_ADDR = $Addr
        $env:VAULT_TOKEN = $Token
        if ($bao) {
            $output = & $bao.Source kv get "-mount=$mount" "-field=$Key" $subPath 2>$null
        }
        else {
            $output = & $vault.Source kv get "-field=$Key" "$mount/$subPath" 2>$null
        }
        if ($LASTEXITCODE -ne 0) { throw "vault CLI failed for '$KvPath' (exit $LASTEXITCODE)." }
        return ($output | Out-String).Trim()
    }

    # REST fallback: kv-v2 GET /v1/<mount>/data/<path>
    $uri = "$($Addr.TrimEnd('/'))/v1/$mount/data/$subPath"
    $response = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 15 `
        -Headers @{ 'X-Vault-Token' = $Token }
    $value = $response.data.data.$Key
    if ($null -eq $value) { throw "key '$Key' not present at '$KvPath'." }
    return [string]$value
}

function Invoke-SyncSecrets {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$CheckOnly,
        [Parameter(Mandatory)][string]$Map
    )

    try {
        $entries = Read-SecretsMap -Path $Map
    }
    catch {
        Write-Warning $_.Exception.Message
        return 2
    }

    $addr = $env:VAULT_ADDR
    if ([string]::IsNullOrWhiteSpace($addr)) { $addr = Get-UserEnvValue 'VAULT_ADDR' }
    $token = $env:VAULT_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) { $token = (Get-UserEnvValue 'VAULT_TOKEN') }

    foreach ($entry in $entries) {
        if ($entry.Verify) {
            Write-Warning "$($entry.Name): path '$($entry.Path)' key '$($entry.Key)' is marked verify:true — confirm it against the live vault, then clear the flag in the map."
        }
    }

    if ($CheckOnly) {
        Write-Host "==> secrets inventory check ($($entries.Count) entries)" -ForegroundColor Cyan
        foreach ($entry in $entries) {
            $present = -not [string]::IsNullOrWhiteSpace((Get-UserEnvValue $entry.Name))
            $status = if ($present) { 'SET' } else { 'MISSING' }
            Write-Host ("  [{0}] {1}  <- {2} : {3}" -f $status, $entry.Name, $entry.Path, $entry.Key)
        }
        if ([string]::IsNullOrWhiteSpace($addr)) {
            Write-Warning 'VAULT_ADDR is not set (process or user env); vault reachability not checked. See docs/secrets-inventory.md.'
        }
        elseif (Test-VaultReachable $addr) {
            Write-Host '  vault: reachable' -ForegroundColor Green
        }
        else {
            Write-Warning 'VAULT_ADDR is set but the vault is unreachable.'
        }
        return 0
    }

    # --- apply mode ---
    if ([string]::IsNullOrWhiteSpace($addr)) {
        Write-Warning 'VAULT_ADDR is not set (process or user env); nothing applied. Set it locally — never commit it. See docs/secrets-inventory.md.'
        return 0
    }
    if (-not (Test-VaultReachable $addr)) {
        Write-Warning 'The vault is unreachable at the configured VAULT_ADDR; nothing applied.'
        return 0
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Warning 'VAULT_TOKEN is not set; nothing applied. Provide it as an env var only — never in a file.'
        return 0
    }

    $failures = 0
    foreach ($entry in $entries) {
        try {
            $value = Get-VaultSecretValue -Addr $addr -Token $token -KvPath $entry.Path -Key $entry.Key
            if ([string]::IsNullOrWhiteSpace($value)) {
                Write-Warning "$($entry.Name): empty value at '$($entry.Path)' key '$($entry.Key)'; skipped."
                $failures++
                continue
            }
            $current = Get-UserEnvValue $entry.Name
            if ($null -ne $current -and $current -ceq $value) {
                Write-Host "  $($entry.Name): already in sync" -ForegroundColor DarkGray
                continue
            }
            if ($PSCmdlet.ShouldProcess($entry.Name, 'set user-level env var from vault')) {
                Set-UserEnvValue $entry.Name $value
                Write-Host "  $($entry.Name): set (value masked)" -ForegroundColor Green
            }
        }
        catch {
            Write-Warning "$($entry.Name): pull failed ($($_.Exception.Message)); skipped."
            $failures++
        }
    }

    if ($failures -gt 0) {
        Write-Warning "$failures of $($entries.Count) entries failed to apply."
        return 1
    }
    return 0
}

# Dot-sourced (tests) defines the functions only; direct execution runs main.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-SyncSecrets -CheckOnly:$Check -Map $MapPath)
}
