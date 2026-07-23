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
        @{ Label = 'aws-access-key-id';   Value = 'AKIA' + ('A1' * 8) }
        @{ Label = 'anthropic-api-key';   Value = 'sk-ant-' + ('a' * 25) }
        @{ Label = 'gitlab-pat';          Value = 'glpat-' + ('g' * 22) }
        @{ Label = 'slack-token';         Value = 'xoxb-' + ('1' * 12) + '-test' }
        @{ Label = 'npm-access-token';    Value = 'npm_' + ('n' * 36) }
        @{ Label = 'pypi-api-token';      Value = 'pypi-' + ('p' * 30) }
        @{ Label = 'jwt';                 Value = 'eyJ' + ('h' * 12) + '.' + ('p' * 12) + '.' + ('s' * 12) }
        @{ Label = 'github-pat-classic';  Value = 'ghp_' + ('G' * 30) }
        @{ Label = 'openai-api-key';      Value = 'sk-' + ('o' * 25) }
    ) {
        param($Label, $Value)
        $dir = New-FixtureDir "detect-$Label" @{ 'config.txt' = "key = $Value`n" }
        $r = Invoke-Scan $dir
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match $Label
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
