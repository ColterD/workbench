# Pester 5 tests for scripts/Sync-Secrets.ps1 — offline only.
# The script is dot-sourced (main body is skipped when dot-sourced) and every
# machine/vault boundary (Get-UserEnvValue, Set-UserEnvValue,
# Test-VaultReachable, Get-VaultSecretValue) is mocked. No network, no real
# user env vars are touched. All token/value strings are synthetic.

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'scripts' 'Sync-Secrets.ps1')
    $script:RepoMap = Join-Path $PSScriptRoot '..' 'scripts' 'sync-secrets.map.json'

    $script:MapJson = @'
{
  "schemaVersion": 1,
  "entries": {
    "WB_TEST_ALPHA": {
      "path": "secret/testing/alpha",
      "key": "value",
      "description": "synthetic fixture entry alpha"
    },
    "WB_TEST_BRAVO": {
      "path": "secret/testing/bravo",
      "key": "token",
      "description": "synthetic fixture entry bravo",
      "verify": true
    }
  }
}
'@

    function New-MapFile {
        param([string]$Name, [string]$Json)
        $path = Join-Path $TestDrive $Name
        [IO.File]::WriteAllText($path, $Json)
        return $path
    }
}

Describe 'Sync-Secrets' {

BeforeEach {
    $script:savedAddr = $env:VAULT_ADDR
    $script:savedToken = $env:VAULT_TOKEN
    $script:setCalls = @()
}

AfterEach {
    $env:VAULT_ADDR = $script:savedAddr
    $env:VAULT_TOKEN = $script:savedToken
}

Describe 'Read-SecretsMap' {
    It 'parses a valid map into sorted entries with verify flags' {
        $map = New-MapFile 'valid.json' $script:MapJson
        $entries = Read-SecretsMap -Path $map
        $entries.Count | Should -Be 2
        $entries[0].Name | Should -Be 'WB_TEST_ALPHA'
        $entries[0].Path | Should -Be 'secret/testing/alpha'
        $entries[0].Key | Should -Be 'value'
        $entries[0].Verify | Should -BeFalse
        $entries[1].Name | Should -Be 'WB_TEST_BRAVO'
        $entries[1].Verify | Should -BeTrue
    }

    It 'validates the repo map shipped with the script' {
        $entries = Read-SecretsMap -Path $script:RepoMap
        $entries.Count | Should -BeGreaterOrEqual 3
        $cloudflare = $entries | Where-Object Name -eq 'CLOUDFLARE_API_TOKEN'
        $cloudflare.Path | Should -Be 'secret/infrastructure/cloudflare'
        $cloudflare.Key | Should -Be 'cloudflare-api-token'
        foreach ($entry in $entries) {
            $entry.Path | Should -Match '^[a-z0-9-]+/.+'
            $entry.Key | Should -Not -BeNullOrEmpty
        }
    }

    It 'throws on malformed JSON' {
        $map = New-MapFile 'broken.json' '{ not json'
        { Read-SecretsMap -Path $map } | Should -Throw '*not valid JSON*'
    }

    It 'throws when entries is missing' {
        $map = New-MapFile 'noentries.json' '{ "schemaVersion": 1 }'
        { Read-SecretsMap -Path $map } | Should -Throw "*no 'entries'*"
    }

    It 'throws when an entry lacks path or key' {
        $map = New-MapFile 'nokey.json' '{ "entries": { "WB_TEST_X": { "path": "secret/a/b" } } }'
        { Read-SecretsMap -Path $map } | Should -Throw "*missing a non-empty 'key'*"
    }

    It 'throws when the map file does not exist' {
        { Read-SecretsMap -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw '*not found*'
    }
}

Describe 'Invoke-SyncSecrets -Check mode' {
    BeforeEach {
        $env:VAULT_ADDR = $null
        $env:VAULT_TOKEN = $null
        $script:map = New-MapFile 'check.json' $script:MapJson
        Mock Get-UserEnvValue {
            if ($Name -eq 'WB_TEST_ALPHA') { return 'synthetic-existing' }
            return $null
        }
        Mock Test-VaultReachable { return $true }
        Mock Write-Host { $script:hostLines += , [string]$Object }
        $script:hostLines = @()
    }

    It 'reports SET/MISSING per entry and always exits 0' {
        $code = Invoke-SyncSecrets -CheckOnly -Map $script:map -WarningVariable +wv 3>$null
        $code | Should -Be 0
        ($script:hostLines -join "`n") | Should -Match '\[SET\] WB_TEST_ALPHA'
        ($script:hostLines -join "`n") | Should -Match '\[MISSING\] WB_TEST_BRAVO'
    }

    It 'surfaces verify:true entries as warnings without failing' {
        $code = Invoke-SyncSecrets -CheckOnly -Map $script:map -WarningVariable +wv 3>$null
        $code | Should -Be 0
        ($wv -join "`n") | Should -Match 'WB_TEST_BRAVO.*verify:true'
    }

    It 'warns when VAULT_ADDR is unset and still exits 0' {
        $code = Invoke-SyncSecrets -CheckOnly -Map $script:map -WarningVariable +wv 3>$null
        $code | Should -Be 0
        ($wv -join "`n") | Should -Match 'VAULT_ADDR is not set'
    }
}

Describe 'Invoke-SyncSecrets apply mode' {
    BeforeEach {
        $script:map = New-MapFile 'apply.json' $script:MapJson
        Mock Set-UserEnvValue { $script:setCalls += , $Name }
    }

    It 'degrades gracefully when VAULT_ADDR is unset (exit 0, nothing applied)' {
        $env:VAULT_ADDR = $null
        $env:VAULT_TOKEN = ('synthetic-proc-' + 'token')
        Mock Get-UserEnvValue { return $null }
        Mock Test-VaultReachable { throw 'must not be called when VAULT_ADDR is unset' }
        $code = Invoke-SyncSecrets -Map $script:map -WarningVariable +wv 3>$null
        $code | Should -Be 0
        ($wv -join "`n") | Should -Match 'VAULT_ADDR is not set'
        Should -Invoke Set-UserEnvValue -Times 0 -Exactly
    }

    It 'degrades gracefully when the vault is unreachable' {
        $env:VAULT_ADDR = 'https://vault.invalid:8200'
        $env:VAULT_TOKEN = ('synthetic-proc-' + 'token')
        Mock Get-UserEnvValue { return $null }
        Mock Test-VaultReachable { return $false }
        $code = Invoke-SyncSecrets -Map $script:map -WarningVariable +wv 3>$null
        $code | Should -Be 0
        ($wv -join "`n") | Should -Match 'unreachable'
        Should -Invoke Set-UserEnvValue -Times 0 -Exactly
    }

    It 'degrades gracefully when VAULT_TOKEN is missing' {
        $env:VAULT_ADDR = 'https://vault.invalid:8200'
        $env:VAULT_TOKEN = $null
        Mock Get-UserEnvValue { return $null }
        Mock Test-VaultReachable { return $true }
        $code = Invoke-SyncSecrets -Map $script:map -WarningVariable +wv 3>$null
        $code | Should -Be 0
        ($wv -join "`n") | Should -Match 'VAULT_TOKEN is not set'
        Should -Invoke Set-UserEnvValue -Times 0 -Exactly
    }

    It 'sets every entry from the vault (values never echoed)' {
        $env:VAULT_ADDR = 'https://vault.invalid:8200'
        $env:VAULT_TOKEN = ('synthetic-proc-' + 'token')
        Mock Get-UserEnvValue { return $null }
        Mock Test-VaultReachable { return $true }
        Mock Get-VaultSecretValue { return 'synthetic-pulled-value' }
        Mock Write-Host { }
        $code = Invoke-SyncSecrets -Map $script:map -WarningVariable +wv 3>$null
        $code | Should -Be 0
        $script:setCalls.Count | Should -Be 2
        $script:setCalls | Should -Contain 'WB_TEST_ALPHA'
        $script:setCalls | Should -Contain 'WB_TEST_BRAVO'
    }

    It 'is idempotent: in-sync entries are not rewritten' {
        $env:VAULT_ADDR = 'https://vault.invalid:8200'
        $env:VAULT_TOKEN = ('synthetic-proc-' + 'token')
        Mock Get-UserEnvValue { return 'synthetic-pulled-value' }
        Mock Test-VaultReachable { return $true }
        Mock Get-VaultSecretValue { return 'synthetic-pulled-value' }
        Mock Write-Host { }
        $code = Invoke-SyncSecrets -Map $script:map 3>$null
        $code | Should -Be 0
        Should -Invoke Set-UserEnvValue -Times 0 -Exactly
    }

    It 'isolates per-entry failures: one bad entry warns, the other applies, exit 1' {
        $env:VAULT_ADDR = 'https://vault.invalid:8200'
        $env:VAULT_TOKEN = ('synthetic-proc-' + 'token')
        Mock Get-UserEnvValue { return $null }
        Mock Test-VaultReachable { return $true }
        Mock Get-VaultSecretValue {
            if ($KvPath -like '*bravo*') { throw 'simulated 404 from vault' }
            return 'synthetic-pulled-value'
        }
        Mock Write-Host { }
        $code = Invoke-SyncSecrets -Map $script:map -WarningVariable +wv 3>$null
        $code | Should -Be 1
        $script:setCalls | Should -Contain 'WB_TEST_ALPHA'
        $script:setCalls | Should -Not -Contain 'WB_TEST_BRAVO'
        ($wv -join "`n") | Should -Match 'WB_TEST_BRAVO.*pull failed'
    }

    It 'returns 2 when the map is invalid' {
        $broken = New-MapFile 'broken-apply.json' '{ not json'
        $code = Invoke-SyncSecrets -Map $broken -WarningVariable +wv 3>$null
        $code | Should -Be 2
        Should -Invoke Set-UserEnvValue -Times 0 -Exactly
    }

    It '-WhatIf applies nothing' {
        $env:VAULT_ADDR = 'https://vault.invalid:8200'
        $env:VAULT_TOKEN = ('synthetic-proc-' + 'token')
        Mock Get-UserEnvValue { return $null }
        Mock Test-VaultReachable { return $true }
        Mock Get-VaultSecretValue { return 'synthetic-pulled-value' }
        Mock Write-Host { }
        $code = Invoke-SyncSecrets -Map $script:map -WhatIf 3>$null
        $code | Should -Be 0
        Should -Invoke Set-UserEnvValue -Times 0 -Exactly
    }
}

}
