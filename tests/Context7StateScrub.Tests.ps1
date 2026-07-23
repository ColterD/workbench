Describe 'Invoke-Context7StateScrub' {
    BeforeAll {
        $scriptPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Invoke-Context7StateScrub.ps1')).Path
    }

    BeforeEach {
        $codexHome = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sessions = Join-Path $codexHome 'sessions\2026\07\14'
        $archived = Join-Path $codexHome 'archived_sessions'
        $null = New-Item -ItemType Directory -Path $sessions -Force
        $null = New-Item -ItemType Directory -Path $archived -Force
        $reportPath = Join-Path $TestDrive 'report.json'
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $keyA = 'ctx7sk-fixture-key-alpha-0123456789'
        $keyB = 'ctx7sk-fixture-key-bravo-9876543210'
    }

    It 'rejects a Codex home whose root is a reparse point' {
        $targetHome = Join-Path $TestDrive ('target-home-' + [guid]::NewGuid().ToString('N'))
        $targetSessions = Join-Path $targetHome 'sessions\2026\07\14'
        $null = New-Item -ItemType Directory -Path $targetSessions -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $targetHome 'archived_sessions') -Force
        $statePath = Join-Path $targetHome '.codex-global-state.json'
        $original = '{"current":"' + $keyA + '"}'
        [IO.File]::WriteAllText($statePath, $original, $utf8)

        $linkedHome = Join-Path $TestDrive ('linked-home-' + [guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Junction -Path $linkedHome -Target $targetHome -ErrorAction Stop
        }
        catch {
            Set-ItResult -Skipped -Because 'The test filesystem cannot create directory junctions.'
            return
        }

        {
            & $scriptPath -Mode Scrub -CodexHome $linkedHome -ReportPath $reportPath | Out-Null
        } | Should -Throw
        (Get-Content -LiteralPath $statePath -Raw) | Should -BeExactly $original
    }

    It 'rejects a <DirectoryName> rollout root that is a reparse point' -TestCases @(
        @{ DirectoryName = 'sessions' }
        @{ DirectoryName = 'archived_sessions' }
    ) {
        param($DirectoryName)

        $junctionHome = Join-Path $TestDrive ('junction-home-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $junctionHome -Force
        if ($DirectoryName -eq 'sessions') {
            $null = New-Item -ItemType Directory -Path (Join-Path $junctionHome 'archived_sessions') -Force
        }
        else {
            $null = New-Item -ItemType Directory -Path (Join-Path $junctionHome 'sessions\2026\07\14') -Force
        }

        $targetDirectory = Join-Path $TestDrive ('rollout-target-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $targetDirectory -Force
        $rollout = Join-Path $targetDirectory 'rollout-outside.jsonl'
        $originalRollout = '{"value":"' + $keyB + '"}' + "`n"
        [IO.File]::WriteAllText($rollout, $originalRollout, $utf8)
        $junctionPath = Join-Path $junctionHome $DirectoryName
        try {
            $null = New-Item -ItemType Junction -Path $junctionPath -Target $targetDirectory -ErrorAction Stop
        }
        catch {
            Set-ItResult -Skipped -Because 'The test filesystem cannot create directory junctions.'
            return
        }

        $statePath = Join-Path $junctionHome '.codex-global-state.json'
        $originalState = '{"current":"' + $keyA + '"}'
        [IO.File]::WriteAllText($statePath, $originalState, $utf8)
        $junctionReport = Join-Path $TestDrive ('junction-report-' + [guid]::NewGuid().ToString('N') + '.json')

        {
            & $scriptPath -Mode Scrub -CodexHome $junctionHome -ReportPath $junctionReport | Out-Null
        } | Should -Throw
        (Get-Content -LiteralPath $statePath -Raw) | Should -BeExactly $originalState
        (Get-Content -LiteralPath $rollout -Raw) | Should -BeExactly $originalRollout
    }

    It 'rejects a nested rollout target directory that is a reparse point' {
        $outsideDirectory = Join-Path $TestDrive ('outside-rollouts-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $outsideDirectory -Force
        $rollout = Join-Path $outsideDirectory 'rollout-outside.jsonl'
        $originalRollout = '{"value":"' + $keyB + '"}' + "`n"
        [IO.File]::WriteAllText($rollout, $originalRollout, $utf8)
        $junctionPath = Join-Path $sessions 'linked-rollouts'
        try {
            $null = New-Item -ItemType Junction -Path $junctionPath -Target $outsideDirectory -ErrorAction Stop
        }
        catch {
            Set-ItResult -Skipped -Because 'The test filesystem cannot create directory junctions.'
            return
        }

        $statePath = Join-Path $codexHome '.codex-global-state.json'
        $originalState = '{"current":"' + $keyA + '"}'
        [IO.File]::WriteAllText($statePath, $originalState, $utf8)

        {
            & $scriptPath -Mode Scrub -CodexHome $codexHome -ReportPath $reportPath | Out-Null
        } | Should -Throw
        (Get-Content -LiteralPath $statePath -Raw) | Should -BeExactly $originalState
        (Get-Content -LiteralPath $rollout -Raw) | Should -BeExactly $originalRollout
    }

    It 'rejects a report whose outside parent is a reparse point' {
        $statePath = Join-Path $codexHome '.codex-global-state.json'
        $originalState = '{"current":"' + $keyA + '"}'
        [IO.File]::WriteAllText($statePath, $originalState, $utf8)
        $reportTarget = Join-Path $codexHome 'report-target'
        $null = New-Item -ItemType Directory -Path $reportTarget -Force
        $reportJunction = Join-Path $TestDrive ('report-junction-' + [guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Junction -Path $reportJunction -Target $reportTarget -ErrorAction Stop
        }
        catch {
            Set-ItResult -Skipped -Because 'The test filesystem cannot create directory junctions.'
            return
        }
        $escapedReport = Join-Path $reportJunction 'report.json'

        {
            & $scriptPath -Mode Audit -CodexHome $codexHome -ReportPath $escapedReport | Out-Null
        } | Should -Throw
        (Get-Content -LiteralPath $statePath -Raw) | Should -BeExactly $originalState
        Test-Path -LiteralPath (Join-Path $reportTarget 'report.json') | Should -Be $false
    }

    It 'rejects an extended-device spelling of the same Codex state file' {
        $statePath = Join-Path $codexHome '.codex-global-state.json'
        $originalState = '{"current":"' + $keyA + '"}'
        [IO.File]::WriteAllText($statePath, $originalState, $utf8)
        $deviceAlias = '\\?\' + $statePath

        {
            & $scriptPath -Mode Audit -CodexHome $codexHome -ReportPath $deviceAlias | Out-Null
        } | Should -Throw

        (Get-Content -LiteralPath $statePath -Raw) | Should -BeExactly $originalState
    }

    It 'canonicalizes dot segments before rejecting the same Codex state file' {
        $statePath = Join-Path $codexHome '.codex-global-state.json'
        $originalState = '{"current":"' + $keyA + '"}'
        [IO.File]::WriteAllText($statePath, $originalState, $utf8)
        $alternateStatePath = Join-Path (Join-Path $codexHome 'sessions\..') '.codex-global-state.json'

        {
            & $scriptPath -Mode Audit -CodexHome $codexHome -ReportPath $alternateStatePath | Out-Null
        } | Should -Throw

        (Get-Content -LiteralPath $statePath -Raw) | Should -BeExactly $originalState
    }

    It 'rejects ambiguous non-local report path syntax' -TestCases @(
        @{ Path = 'C:relative-report.json' }
        @{ Path = '\\server\share\report.json' }
        @{ Path = '\\.\C:\report.json' }
    ) {
        param($Path)

        {
            & $scriptPath -Mode Audit -CodexHome $codexHome -ReportPath $Path | Out-Null
        } | Should -Throw
    }

    It 'redacts every discovered key without creating a secret-bearing backup' {
        [IO.File]::WriteAllText((Join-Path $codexHome '.codex-global-state.json'), ('{"current":"' + $keyA + '"}'), $utf8)
        [IO.File]::WriteAllText((Join-Path $codexHome '.codex-global-state.json.bak'), ('{"old":"' + $keyB + '"}'), $utf8)
        $rollout = Join-Path $sessions 'rollout-fixture.jsonl'
        [IO.File]::WriteAllText($rollout, ((('{"value":"' + $keyA + '"}') + "`n" + ('{"value":"' + $keyB + '"}') + "`n")), $utf8)

        & $scriptPath -Mode Scrub -CodexHome $codexHome -ReportPath $reportPath | Out-Null

        $allText = (@(
                Get-Content -LiteralPath (Join-Path $codexHome '.codex-global-state.json') -Raw
                Get-Content -LiteralPath (Join-Path $codexHome '.codex-global-state.json.bak') -Raw
                Get-Content -LiteralPath $rollout -Raw
                Get-Content -LiteralPath $reportPath -Raw
            ) -join "`n")
        $allText | Should -Not -Match 'ctx7sk-'
        (Get-ChildItem -LiteralPath $codexHome -Recurse -File -Filter '*.tmp').Count | Should -Be 0

        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $report.Success | Should -Be $true
        $report.AffectedFiles | Should -Be 3
        $report.OccurrencesFound | Should -Be 4
        $report.RemainingOccurrences | Should -Be 0
        $report.DistinctFingerprints | Should -Be 2
        @($report.Fingerprints).Count | Should -Be 2
        foreach ($fingerprint in @($report.Fingerprints)) {
            $fingerprint | Should -Match '^[0-9a-f]{12}$'
        }
    }

    It 'validates every target before changing any target' {
        $validPath = Join-Path $codexHome '.codex-global-state.json'
        $invalidPath = Join-Path $codexHome '.codex-global-state.json.bak'
        [IO.File]::WriteAllText($validPath, ('{"current":"' + $keyA + '"}'), $utf8)
        [IO.File]::WriteAllText($invalidPath, ('{"broken":"' + $keyB + '"'), $utf8)

        $threw = $false
        try {
            & $scriptPath -Mode Scrub -CodexHome $codexHome -ReportPath $reportPath | Out-Null
        }
        catch {
            $threw = $true
        }
        $threw | Should -Be $true

        (Get-Content -LiteralPath $validPath -Raw) | Should -Match ([regex]::Escape($keyA))
        (Get-Content -LiteralPath $invalidPath -Raw) | Should -Match ([regex]::Escape($keyB))
    }

    It 'validates every affected rollout before changing state files' {
        $statePath = Join-Path $codexHome '.codex-global-state.json'
        $rollout = Join-Path $sessions 'rollout-malformed.jsonl'
        [IO.File]::WriteAllText($statePath, ('{"current":"' + $keyA + '"}'), $utf8)
        [IO.File]::WriteAllText($rollout, ('{"value":"' + $keyB + '"' + "`n"), $utf8)

        $threw = $false
        try {
            & $scriptPath -Mode Scrub -CodexHome $codexHome -ReportPath $reportPath | Out-Null
        }
        catch {
            $threw = $true
        }
        $threw | Should -Be $true

        (Get-Content -LiteralPath $statePath -Raw) | Should -Match ([regex]::Escape($keyA))
        (Get-Content -LiteralPath $rollout -Raw) | Should -Match ([regex]::Escape($keyB))
    }

    It 'validates unaffected rollouts before changing state files' {
        $statePath = Join-Path $codexHome '.codex-global-state.json'
        $rollout = Join-Path $sessions 'rollout-malformed-unaffected.jsonl'
        $originalState = '{"current":"' + $keyA + '"}'
        $originalRollout = '{"unrelated":' + "`n"
        [IO.File]::WriteAllText($statePath, $originalState, $utf8)
        [IO.File]::WriteAllText($rollout, $originalRollout, $utf8)

        {
            & $scriptPath -Mode Scrub -CodexHome $codexHome -ReportPath $reportPath | Out-Null
        } | Should -Throw

        (Get-Content -LiteralPath $statePath -Raw) | Should -BeExactly $originalState
        (Get-Content -LiteralPath $rollout -Raw) | Should -BeExactly $originalRollout
    }

    It 'discovers rollouts hidden by dot directories and ignore rules' {
        $hiddenDirectory = Join-Path $sessions '.ignored'
        $null = New-Item -ItemType Directory -Path $hiddenDirectory -Force
        [IO.File]::WriteAllText((Join-Path $sessions '.ignore'), "rollout-*.jsonl`n", $utf8)
        $rollout = Join-Path $hiddenDirectory 'rollout-hidden.jsonl'
        [IO.File]::WriteAllText($rollout, ('{"value":"' + $keyA + '"}' + "`n"), $utf8)

        & $scriptPath -Mode Scrub -CodexHome $codexHome -ReportPath $reportPath | Out-Null

        (Get-Content -LiteralPath $rollout -Raw) | Should -Not -Match 'ctx7sk-'
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $report.Success | Should -Be $true
        $report.AffectedFiles | Should -Be 1
        $report.RemainingOccurrences | Should -Be 0
    }

    It 'rejects invalid UTF-8 before changing any target' {
        $statePath = Join-Path $codexHome '.codex-global-state.json'
        $backupPath = Join-Path $codexHome '.codex-global-state.json.bak'
        [IO.File]::WriteAllText($statePath, ('{"current":"' + $keyA + '"}'), $utf8)
        [IO.File]::WriteAllBytes($backupPath, [byte[]](123, 34, 120, 34, 58, 34, 195, 40, 34, 125))

        $threw = $false
        try {
            & $scriptPath -Mode Scrub -CodexHome $codexHome -ReportPath $reportPath | Out-Null
        }
        catch {
            $threw = $true
        }
        $threw | Should -Be $true

        (Get-Content -LiteralPath $statePath -Raw) | Should -Match ([regex]::Escape($keyA))
    }

    It 'preserves UTF-8 BOMs, CRLF endings, timestamps, and ACLs' {
        $statePath = Join-Path $codexHome '.codex-global-state.json'
        $rollout = Join-Path $sessions 'rollout-metadata.jsonl'
        $utf8Bom = [System.Text.UTF8Encoding]::new($true, $true)
        [IO.File]::WriteAllText($statePath, ('{"current":"' + $keyA + '"}'), $utf8Bom)
        [IO.File]::WriteAllText($rollout, ('{"value":"' + $keyB + '"}' + "`r`n"), $utf8Bom)

        $timestamp = [datetime]::SpecifyKind([datetime]'2024-01-02T03:04:05', [DateTimeKind]::Utc)
        [IO.File]::SetLastWriteTimeUtc($statePath, $timestamp)
        [IO.File]::SetLastWriteTimeUtc($rollout, $timestamp)
        $stateAcl = (Get-Acl -LiteralPath $statePath).Sddl
        $rolloutAcl = (Get-Acl -LiteralPath $rollout).Sddl

        & $scriptPath -Mode Scrub -CodexHome $codexHome -ReportPath $reportPath | Out-Null

        [BitConverter]::ToString([IO.File]::ReadAllBytes($statePath), 0, 3) | Should -BeExactly 'EF-BB-BF'
        [BitConverter]::ToString([IO.File]::ReadAllBytes($rollout), 0, 3) | Should -BeExactly 'EF-BB-BF'
        $rolloutText = [IO.File]::ReadAllText($rollout, [System.Text.UTF8Encoding]::new($false, $true))
        $rolloutText.EndsWith("`r`n") | Should -Be $true
        ($rolloutText -replace "`r`n", '') | Should -Not -Match "[`r`n]"
        (Get-Item -LiteralPath $statePath).LastWriteTimeUtc.Ticks | Should -Be $timestamp.Ticks
        (Get-Item -LiteralPath $rollout).LastWriteTimeUtc.Ticks | Should -Be $timestamp.Ticks
        (Get-Acl -LiteralPath $statePath).Sddl | Should -BeExactly $stateAcl
        (Get-Acl -LiteralPath $rollout).Sddl | Should -BeExactly $rolloutAcl
    }

    It 'preserves read-only attributes without losing timestamps' {
        $statePath = Join-Path $codexHome '.codex-global-state.json'
        [IO.File]::WriteAllText($statePath, ('{"current":"' + $keyA + '"}'), $utf8)
        $timestamp = [datetime]::SpecifyKind([datetime]'2024-02-03T04:05:06', [DateTimeKind]::Utc)
        [IO.File]::SetLastWriteTimeUtc($statePath, $timestamp)
        $originalAttributes = [IO.File]::GetAttributes($statePath)
        [IO.File]::SetAttributes($statePath, ($originalAttributes -bor [IO.FileAttributes]::ReadOnly))

        try {
            & $scriptPath -Mode Scrub -CodexHome $codexHome -ReportPath $reportPath | Out-Null

            (Get-Item -LiteralPath $statePath).LastWriteTimeUtc.Ticks | Should -Be $timestamp.Ticks
            ([IO.File]::GetAttributes($statePath) -band [IO.FileAttributes]::ReadOnly) | Should -Be ([IO.FileAttributes]::ReadOnly)
            (Get-Content -LiteralPath $statePath -Raw) | Should -Not -Match 'ctx7sk-'
        }
        finally {
            if (Test-Path -LiteralPath $statePath) {
                [IO.File]::SetAttributes($statePath, $originalAttributes)
            }
        }
    }

    It 'leaves the source intact and removes temporary files when replacement is blocked' {
        $statePath = Join-Path $codexHome '.codex-global-state.json'
        $original = '{"current":"' + $keyA + '"}'
        [IO.File]::WriteAllText($statePath, $original, $utf8)
        $lock = [IO.FileStream]::new(
            $statePath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )

        try {
            $threw = $false
            try {
                & $scriptPath -Mode Scrub -CodexHome $codexHome -ReportPath $reportPath | Out-Null
            }
            catch {
                $threw = $true
            }
            $threw | Should -Be $true
            (Get-Content -LiteralPath $statePath -Raw) | Should -BeExactly $original
            (Get-ChildItem -LiteralPath $codexHome -Recurse -File -Force -Filter '*.tmp').Count | Should -Be 0
        }
        finally {
            $lock.Dispose()
        }
    }

    It 'never writes an error report over a Codex state target' {
        $statePath = Join-Path $codexHome '.codex-global-state.json'
        $original = '{"current":"' + $keyA + '"}'
        [IO.File]::WriteAllText($statePath, $original, $utf8)

        $threw = $false
        try {
            & $scriptPath -Mode Audit -CodexHome $codexHome -ReportPath $statePath | Out-Null
        }
        catch {
            $threw = $true
        }
        $threw | Should -Be $true

        (Get-Content -LiteralPath $statePath -Raw) | Should -BeExactly $original
    }

    It 'fails closed when another scrub owns the single-instance mutex' {
        $statePath = Join-Path $codexHome '.codex-global-state.json'
        $original = '{"current":"' + $keyA + '"}'
        [IO.File]::WriteAllText($statePath, $original, $utf8)
        $readyPath = Join-Path $TestDrive ('mutex-ready-' + [guid]::NewGuid().ToString('N'))
        $releasePath = Join-Path $TestDrive ('mutex-release-' + [guid]::NewGuid().ToString('N'))
        $job = Start-Job -ArgumentList $readyPath, $releasePath -ScriptBlock {
            param($ReadyPath, $ReleasePath)
            $mutex = [System.Threading.Mutex]::new($false, 'Local\Context7StateScrub')
            $owned = $false
            try {
                $owned = $mutex.WaitOne(10000, $false)
                if (-not $owned) {
                    throw 'Fixture could not acquire the scrub mutex.'
                }
                [IO.File]::WriteAllText($ReadyPath, 'ready')
                $deadline = [datetime]::UtcNow.AddSeconds(10)
                while (-not (Test-Path -LiteralPath $ReleasePath) -and [datetime]::UtcNow -lt $deadline) {
                    Start-Sleep -Milliseconds 50
                }
            }
            finally {
                if ($owned) {
                    $mutex.ReleaseMutex()
                }
                $mutex.Dispose()
            }
        }

        try {
            $deadline = [datetime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $readyPath) -and [datetime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 50
            }
            (Test-Path -LiteralPath $readyPath) | Should -Be $true

            $threw = $false
            try {
                & $scriptPath -Mode Audit -CodexHome $codexHome -ReportPath $reportPath | Out-Null
            }
            catch {
                $threw = $true
            }
            $threw | Should -Be $true
            (Get-Content -LiteralPath $statePath -Raw) | Should -BeExactly $original
        }
        finally {
            [IO.File]::WriteAllText($releasePath, 'release')
            $null = Wait-Job -Job $job -Timeout 5 -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    It 'relaunches once when a later graceful close fails after shutdown has begun' {
        $fakeExecutable = Join-Path $TestDrive ('Codex-' + [guid]::NewGuid().ToString('N') + '.exe')
        [IO.File]::WriteAllText($fakeExecutable, 'fixture', $utf8)
        $firstGui = [pscustomobject]@{
            ProcessName      = 'Codex'
            MainWindowHandle = [intptr]1
            Path             = $fakeExecutable
        }
        $secondGui = [pscustomobject]@{
            ProcessName      = 'Codex'
            MainWindowHandle = [intptr]2
            Path             = $fakeExecutable
        }
        $firstGui | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { return $true }
        $secondGui | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { return $false }
        $processState = @{ Calls = 0 }

        Mock Get-Process {
            $processState.Calls++
            if ($processState.Calls -eq 1) {
                return @($firstGui, $secondGui)
            }
            return @()
        } -ParameterFilter { $Name -eq 'Codex' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq $fakeExecutable }

        {
            & $scriptPath `
                -Mode Scrub `
                -CodexHome $codexHome `
                -ReportPath $reportPath `
                -CloseAndRelaunchCodex | Out-Null
        } | Should -Throw

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly `
            -ParameterFilter { $FilePath -eq $fakeExecutable }
    }

    It 'does not relaunch when a GUI remains after a later graceful close failure' {
        $fakeExecutable = Join-Path $TestDrive ('Codex-' + [guid]::NewGuid().ToString('N') + '.exe')
        [IO.File]::WriteAllText($fakeExecutable, 'fixture', $utf8)
        $firstGui = [pscustomobject]@{
            ProcessName      = 'Codex'
            MainWindowHandle = [intptr]1
            Path             = $fakeExecutable
        }
        $secondGui = [pscustomobject]@{
            ProcessName      = 'Codex'
            MainWindowHandle = [intptr]2
            Path             = $fakeExecutable
        }
        $firstGui | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { return $true }
        $secondGui | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { return $false }
        $processState = @{ Calls = 0 }

        Mock Get-Process {
            $processState.Calls++
            if ($processState.Calls -eq 1) {
                return @($firstGui, $secondGui)
            }
            return @($secondGui)
        } -ParameterFilter { $Name -eq 'Codex' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq $fakeExecutable }

        {
            & $scriptPath `
                -Mode Scrub `
                -CodexHome $codexHome `
                -ReportPath $reportPath `
                -CloseAndRelaunchCodex | Out-Null
        } | Should -Throw

        Should -Invoke -CommandName Start-Process -Times 0 -Exactly `
            -ParameterFilter { $FilePath -eq $fakeExecutable }
    }

    It 'relaunches once when shutdown times out after the GUI close request' {
        $fakeExecutable = Join-Path $TestDrive ('Codex-' + [guid]::NewGuid().ToString('N') + '.exe')
        [IO.File]::WriteAllText($fakeExecutable, 'fixture', $utf8)
        $guiProcess = [pscustomobject]@{
            ProcessName      = 'Codex'
            MainWindowHandle = [intptr]1
            Path             = $fakeExecutable
        }
        $backgroundProcess = [pscustomobject]@{
            ProcessName      = 'Codex'
            MainWindowHandle = [intptr]0
            Path             = $fakeExecutable
        }
        $guiProcess | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { return $true }
        $processState = @{ Calls = 0 }

        Mock Get-Process {
            $processState.Calls++
            if ($processState.Calls -eq 1) {
                return @($guiProcess)
            }
            return @($backgroundProcess)
        } -ParameterFilter { $Name -eq 'Codex' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq $fakeExecutable }

        {
            & $scriptPath `
                -Mode Scrub `
                -CodexHome $codexHome `
                -ReportPath $reportPath `
                -CloseAndRelaunchCodex `
                -GraceSeconds 5 | Out-Null
        } | Should -Throw

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly `
            -ParameterFilter { $FilePath -eq $fakeExecutable }
    }

    It 'audits without modifying files' {
        $statePath = Join-Path $codexHome '.codex-global-state.json'
        $original = '{"current":"' + $keyA + '"}'
        [IO.File]::WriteAllText($statePath, $original, $utf8)

        & $scriptPath -Mode Audit -CodexHome $codexHome -ReportPath $reportPath | Out-Null

        (Get-Content -LiteralPath $statePath -Raw) | Should -BeExactly $original
        $reportText = Get-Content -LiteralPath $reportPath -Raw
        $reportText | Should -Not -Match 'ctx7sk-'
        $reportText | Should -Not -Match ([regex]::Escape($codexHome))
        $reportText | Should -Not -Match ([regex]::Escape($keyA))
        $report = $reportText | ConvertFrom-Json
        $report.Success | Should -Be $true
        $report.AffectedFiles | Should -Be 1
        $report.OccurrencesFound | Should -Be 1
        $report.RemainingOccurrences | Should -BeNullOrEmpty
    }
}
