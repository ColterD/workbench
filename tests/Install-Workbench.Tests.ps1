# Pester 5 tests for bootstrap/Install-Workbench.ps1 in -NoInstall mode.
# -NoInstall must be check-only: it reports but never changes machine state.

BeforeAll {
    $script:Bootstrap = Join-Path $PSScriptRoot '..' 'bootstrap' 'Install-Workbench.ps1'
    $script:PwshExe = Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')

    # Capture env state before, run the checklist once for all assertions.
    $script:RunnerVarBefore = [Environment]::GetEnvironmentVariable('CODERABBIT_RUNNER', 'User')
    $script:Output = & $script:PwshExe -NoProfile -ExecutionPolicy Bypass -File $script:Bootstrap -NoInstall 2>&1 | Out-String
    $script:ExitCode = $LASTEXITCODE
    $script:RunnerVarAfter = [Environment]::GetEnvironmentVariable('CODERABBIT_RUNNER', 'User')
}

Describe 'Install-Workbench -NoInstall checklist' {
    It 'exits 0 when nothing FAILs (MANUAL does not fail the run)' {
        $script:ExitCode | Should -Be 0
        $script:Output | Should -Not -Match '\bFAIL\b'
    }

    It 'prints the summary line' {
        $script:Output | Should -Match '\d+ pass, \d+ fixed, \d+ manual, \d+ failed'
    }

    It 'reports every core check with a valid status' {
        foreach ($check in @('Git', 'PowerShell 7', 'uv', 'Snyk CLI', 'Docker daemon',
                             'Docker CLI', 'WSL Debian', 'Pester',
                             'env:CODERABBIT_RUNNER', 'env:SNYK_TOKEN')) {
            $script:Output | Should -Match ([regex]::Escape($check))
        }
        # statuses are constrained to the documented vocabulary
        $statusLines = $script:Output -split "`r?`n" | Where-Object { $_ -match '\b(PASS|FIXED|MANUAL|FAIL)\b' }
        $statusLines.Count | Should -BeGreaterThan 8
    }

    It 'reports profile checks' {
        $script:Output | Should -Match 'profile:'
    }

    It 'never fixes anything in -NoInstall mode' {
        # case-SENSITIVE: the summary line ("0 fixed") must not count
        $script:Output | Should -Not -CMatch '\bFIXED\b'
    }

    It 'does not modify user-level env vars in -NoInstall mode' {
        $script:RunnerVarAfter | Should -Be $script:RunnerVarBefore
    }
}
