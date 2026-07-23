# Pester 5 tests for scripts/Invoke-SecretScan.ps1
# All fixture secrets are SYNTHETIC and built by concatenation so the literal
# values never appear in this file (keeps this repo's own scan clean).

BeforeAll {
    $script:Scanner = Join-Path $PSScriptRoot '..' 'scripts' 'Invoke-SecretScan.ps1'
    # pwsh that runs these tests also runs the scanner; $PSHOME always has pwsh(.exe)
    $script:PwshExe = Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')

    function Invoke-Scan {
        param([string]$Target, [switch]$Staged)
        $argList = @('-NoProfile', '-File', $script:Scanner, '-Path', $Target)
        if ($Staged) { $argList += '-Staged' }
        $output = & $script:PwshExe @argList 2>&1 | Out-String
        return @{ ExitCode = $LASTEXITCODE; Output = $output }
    }

    function New-FixtureDir {
        param([string]$Name, [hashtable]$Files)
        $dir = Join-Path $TestDrive $Name
        [void][IO.Directory]::CreateDirectory($dir)
        foreach ($f in $Files.GetEnumerator()) {
            [IO.File]::WriteAllText((Join-Path $dir $f.Key), $f.Value)
        }
        return $dir
    }

    function New-TestRepo {
        param([string]$Name)
        $repo = Join-Path $TestDrive $Name
        [void][IO.Directory]::CreateDirectory($repo)
        git -C $repo init -q
        git -C $repo config user.name 'test'
        git -C $repo config user.email 'test@example.invalid'
        [IO.File]::WriteAllText((Join-Path $repo 'readme.txt'), "clean`n")
        git -C $repo add readme.txt
        git -C $repo commit -qm 'init'
        return $repo
    }
}

Describe 'Invoke-SecretScan detection' {
    It 'detects <Label>' -TestCases @(
        @{ Label = 'aws-access-key-id';          Value = 'AKIA' + ('A1' * 8) }
        @{ Label = 'anthropic-api-key';          Value = 'sk-ant-' + ('a' * 25) }
        @{ Label = 'gitlab-pat';                 Value = 'glpat-' + ('g' * 22) }
        @{ Label = 'slack-token';                Value = 'xoxb-' + ('1' * 12) + '-test' }
        @{ Label = 'npm-access-token';           Value = 'npm_' + ('n' * 36) }
        @{ Label = 'pypi-api-token';             Value = 'pypi-' + ('p' * 30) }
        @{ Label = 'jwt';                        Value = 'eyJ' + ('h' * 12) + '.' + ('p' * 12) + '.' + ('s' * 12) }
        @{ Label = 'github-pat-classic';         Value = 'ghp_' + ('G' * 30) }
        @{ Label = 'openai-api-key';             Value = 'sk-' + ('o' * 25) }
        @{ Label = 'github-oauth-token';         Value = 'gho_' + ('O' * 30) }
        @{ Label = 'gitlab-runner-token';        Value = 'glrt-' + ('r' * 22) }
        @{ Label = 'gitlab-ci-job-token';        Value = 'glcbt-' + ('c' * 22) }
        @{ Label = 'openai-project-key';         Value = 'sk-proj-' + ('P' * 25) }
        @{ Label = 'stripe-key';                 Value = 'sk_live_' + ('S' * 24) }
        @{ Label = 'google-api-key';             Value = 'AIza' + ('G' * 35) }
        @{ Label = 'google-oauth-client-secret'; Value = 'GOCSPX-' + ('g' * 24) }
        @{ Label = 'sendgrid-api-key';           Value = 'SG.' + ('s' * 20) + '.' + ('g' * 20) }
        @{ Label = 'twilio-api-key';             Value = 'SK' + ('a1' * 16) }
        @{ Label = 'digitalocean-pat';           Value = 'dop_v1_' + ('d' * 64) }
        @{ Label = 'docker-hub-pat';             Value = 'dckr_pat_' + ('D' * 25) }
        @{ Label = 'huggingface-token';          Value = 'hf_' + ('H' * 32) }
        @{ Label = 'groq-api-key';               Value = 'gsk_' + ('G' * 24) }
        @{ Label = 'replicate-api-token';        Value = 'r8_' + ('R' * 24) }
        @{ Label = 'slack-webhook';              Value = 'https://hooks.slack.com/services/T' + ('A' * 9) + '/B' + ('B' * 9) + '/' + ('C' * 20) }
        @{ Label = 'discord-webhook';            Value = 'https://discord.com/api/webhooks/' + ('1' * 18) + '/' + ('w' * 24) }
        @{ Label = 'telegram-bot-token';         Value = ('7' * 9) + ':' + ('T' * 35) }
        @{ Label = 'shopify-token';              Value = 'shpat_' + ('f' * 32) }
        @{ Label = 'square-token';               Value = 'sq0atp-' + ('s' * 24) }
        @{ Label = 'new-relic-api-key';          Value = 'NRAK-' + ('N' * 27) }
        @{ Label = 'okta-ssws-token';            Value = 'SSWS ' + ('O' * 24) }
        @{ Label = 'linear-api-key';             Value = 'lin_api_' + ('L' * 40) }
        @{ Label = 'notion-token';               Value = 'ntn_' + ('N' * 24) }
        @{ Label = 'figma-token';                Value = 'figd_' + ('F' * 24) }
        @{ Label = 'airtable-pat';               Value = 'pat' + ('a' * 14) + '.' + ('b' * 64) }
        @{ Label = 'age-secret-key';             Value = 'AGE-SECRET-KEY-1' + ('K' * 58) }
        @{ Label = 'azure-storage-account-key';  Value = 'AccountKey=' + ('Z' * 44) }
        @{ Label = 'uri-embedded-credentials';   Value = 'postgres://workbench:' + ('p' * 16) + '@db.internal:5432/app' }
        @{ Label = 'kubeconfig-client-key';      Value = 'client-key-data: ' + ('Q' * 48) }
        @{ Label = 'supabase-pat';               Value = 'sbp_' + ('5' * 40) }
        @{ Label = 'planetscale-token';          Value = 'pscale_tkn_' + ('t' * 24) }
        @{ Label = 'neon-api-key';               Value = 'napi_' + ('n' * 24) }
        @{ Label = 'doppler-token';              Value = 'dp.st.prod.' + ('D' * 30) }
    ) {
        param($Label, $Value)
        $dir = New-FixtureDir "detect-$Label" @{ 'config.txt' = "key = $Value`n" }
        $r = Invoke-Scan $dir
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match $Label
    }
}

Describe 'Invoke-SecretScan generic assignment semantics' {
    It 'detects a literal credential assignment' {
        $dir = New-FixtureDir 'generic-hit' @{ 'app.py' = 'token = "' + ('z' * 20) + '"' + "`n" }
        $r = Invoke-Scan $dir
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'generic-credential-assignment'
    }

    It 'does not hop across lines in env-style files' {
        # SECRET= at end of line, next line is another variable name
        $text = "SECRET=`nDASHBOARD_SESSION_SECRET=abc`n"
        $dir = New-FixtureDir 'generic-multiline' @{ '.env.example' = $text }
        $r = Invoke-Scan $dir
        $r.ExitCode | Should -Be 0
    }

    It 'ignores attribute-chain references, not literals' -TestCases @(
        @{ Label = 'self attribute';     Text = 'secret = self.dashboard_session_secret_value' }
        @{ Label = 'settings attribute'; Text = 'token = settings.mediamanager_token_value' }
        @{ Label = 'config attribute';   Text = 'password = config.database_password_value' }
    ) {
        param($Label, $Text)
        $dir = New-FixtureDir "attr-$($Label -replace ' ','-')" @{ 'app.py' = "$Text`n" }
        $r = Invoke-Scan $dir
        $r.ExitCode | Should -Be 0
    }

    It 'ignores unquoted identifier/call references in code files' -TestCases @(
        @{ Label = 'bare identifier';  Text = 'secret = dashboard_session_secret' }
        @{ Label = 'function call';    Text = 'secret = resolve_dashboard_session_secret(settings, store)' }
        @{ Label = 'camelCase var';    Text = 'apiKey = currentApiKeyValueHolder' }
    ) {
        param($Label, $Text)
        $dir = New-FixtureDir "ident-$($Label -replace ' ','-')" @{ 'app.py' = "$Text`n" }
        $r = Invoke-Scan $dir
        $r.ExitCode | Should -Be 0
    }

    It 'still flags bare values in env files (identifier rule is code-only)' {
        $dir = New-FixtureDir 'env-bare' @{ '.env' = 'SECRET=actualsecretvaluethatislonge' + "`n" }
        $r = Invoke-Scan $dir
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'generic-credential-assignment'
    }
}

Describe 'Invoke-SecretScan false-positive regression' {
    It 'ignores <Label>' -TestCases @(
        @{ Label = 'short sk- value';          Text = 'api key sk-abc123' }
        @{ Label = 'short password';           Text = 'password = "changeme"' }
        @{ Label = 'npm prose';                Text = 'run npm_install or npm test to verify' }
        @{ Label = 'xoxo gossip';              Text = 'xoxo, gossip girl' }
        @{ Label = 'single-segment eyJ';       Text = 'prefix eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 suffix' }
        @{ Label = 'short AKIA';               Text = 'AKIA123 too short' }
        @{ Label = 'placeholder assignment';   Text = 'api_key = YOUR_TOKEN_HERE' }
        @{ Label = 'short sk-proj';            Text = 'sk-proj-abc123 is truncated' }
        @{ Label = 'stripe public key';        Text = 'publishable pk_live_4eC39HqLyjWDarjtT1zdp7dc is safe' }
        @{ Label = 'url without userinfo';     Text = 'postgres://db.internal:5432/app has no creds' }
        @{ Label = 'plain https url';          Text = 'see https://example.com/some/path for details' }
        @{ Label = 'short AIza';               Text = 'AIza123 is too short' }
        @{ Label = 'incomplete slack hook';    Text = 'https://hooks.slack.com/services/T0000 only' }
        @{ Label = 'short telegram';           Text = '12345678:tooshort' }
        @{ Label = 'ssh public key';           Text = 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB user@host' }
        @{ Label = 'pat prose';                Text = 'patience is a virtue, pattern or not' }
    ) {
        param($Label, $Text)
        $dir = New-FixtureDir "fp-$($Label -replace ' ','-')" @{ 'notes.txt' = "$Text`n" }
        $r = Invoke-Scan $dir
        $r.ExitCode | Should -Be 0
    }
}

Describe 'Invoke-SecretScan allowlist' {
    It 'suppresses an allowlisted synthetic value' {
        $token = 'ghp_' + ('G' * 30)
        $dir = New-FixtureDir 'allow-suppress' @{
            'config.txt'         = "token = $token`n"
            '.secret-scan-allow' = "$token`n"
        }
        $r = Invoke-Scan $dir
        $r.ExitCode | Should -Be 0
    }

    It 'ignores comment lines and blank lines in the allowlist' {
        $token = 'ghp_' + ('G' * 30)
        $dir = New-FixtureDir 'allow-comments' @{
            'config.txt'         = "token = $token`n"
            '.secret-scan-allow' = "# known false positives`n`n  # synthetic fixture`n$token`n"
        }
        $r = Invoke-Scan $dir
        $r.ExitCode | Should -Be 0
    }

    It 'still flags values not present in the allowlist' {
        $listed = 'ghp_' + ('G' * 30)
        $other = 'glpat-' + ('g' * 22)
        $dir = New-FixtureDir 'allow-miss' @{
            'config.txt'         = "a = $listed`nb = $other`n"
            '.secret-scan-allow' = "# only the github one is allowed`n$listed`n"
        }
        $r = Invoke-Scan $dir
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'gitlab-pat'
        $r.Output | Should -Not -Match 'github-pat-classic'
    }
}

Describe 'Invoke-SecretScan -Staged mode' {
    It 'flags a staged secret' {
        $repo = New-TestRepo 'staged-hit'
        [IO.File]::WriteAllText((Join-Path $repo 'secret.txt'), ('token = ghp_' + ('G' * 30)))
        git -C $repo add secret.txt
        $r = Invoke-Scan $repo -Staged
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'github-pat-classic'
    }

    It 'ignores secrets that are not staged' {
        $repo = New-TestRepo 'staged-unstaged'
        [IO.File]::WriteAllText((Join-Path $repo 'secret.txt'), ('token = ghp_' + ('G' * 30)))
        $r = Invoke-Scan $repo -Staged
        $r.ExitCode | Should -Be 0
    }

    It 'scans index content, not the working tree' {
        $repo = New-TestRepo 'staged-index-content'
        [IO.File]::WriteAllText((Join-Path $repo 'app.txt'), "clean config`n")
        git -C $repo add app.txt
        # working tree now has a secret, but the staged blob is clean
        [IO.File]::WriteAllText((Join-Path $repo 'app.txt'), ('token = ghp_' + ('G' * 30)))
        $r = Invoke-Scan $repo -Staged
        $r.ExitCode | Should -Be 0
    }

    It 'fails outside a git repository' {
        $dir = New-FixtureDir 'staged-norepo' @{ 'a.txt' = "hi`n" }
        $r = Invoke-Scan $dir -Staged
        $r.ExitCode | Should -Not -Be 0
    }
}
