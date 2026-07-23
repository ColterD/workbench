# Pester 5 tests for scripts/Invoke-PrePublishGate.ps1
# External tools (uv, npm, docker, snyk, the CodeRabbit runner) are mocked
# with PATH shims that log invocations — the tests assert WHICH steps run
# under each flag combination, never real lint/test/build outcomes.

BeforeAll {
    $script:Gate = Join-Path $PSScriptRoot '..' 'scripts' 'Invoke-PrePublishGate.ps1'
    $script:PwshExe = Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')

    function New-ShimDir {
        param([string]$Name, [string[]]$Tools)
        $dir = Join-Path $TestDrive $Name
        [void][IO.Directory]::CreateDirectory($dir)
        foreach ($tool in $Tools) {
            if ($IsWindows) {
                $shim = Join-Path $dir "$tool.cmd"
                [IO.File]::WriteAllText($shim, "@echo off`r`necho $tool %* >> `"%GATE_SHIM_LOG%`"`r`nexit /b 0`r`n")
            } else {
                $shim = Join-Path $dir $tool
                [IO.File]::WriteAllText($shim, "#!/bin/sh`necho $tool `"`$@`" >> `"`$GATE_SHIM_LOG`"`nexit 0`n")
                chmod +x $shim
            }
        }
        return $dir
    }

    function New-GateProject {
        param([string]$Name, [hashtable]$Files)
        $dir = Join-Path $TestDrive $Name
        [void][IO.Directory]::CreateDirectory($dir)
        foreach ($f in $Files.GetEnumerator()) {
            [IO.File]::WriteAllText((Join-Path $dir $f.Key), $f.Value)
        }
        return $dir
    }

    function Invoke-Gate {
        param([string]$Project, [string]$ShimDir, [string[]]$ExtraArgs)
        $log = Join-Path $TestDrive 'shim.log'
        if (Test-Path $log) { Remove-Item $log -Force }
        $env:GATE_SHIM_LOG = $log
        $oldPath = $env:PATH
        $env:PATH = "$ShimDir$([IO.Path]::PathSeparator)$oldPath"
        try {
            $output = & $script:PwshExe -NoProfile -File $script:Gate -ProjectPath $Project @ExtraArgs 2>&1 | Out-String
        } finally {
            $env:PATH = $oldPath
        }
        $logged = (Test-Path $log) ? (Get-Content $log -Raw) : ''
        return @{ ExitCode = $LASTEXITCODE; Output = $output; Log = $logged }
    }

    function New-FakeCodeRabbitRunner {
        # exits with $env:FAKE_CR_EXIT and records that it was invoked
        $runner = Join-Path $TestDrive 'fake-runner.ps1'
        [IO.File]::WriteAllText($runner, "Add-Content -Path `"`$env:GATE_SHIM_LOG`" -Value 'coderabbit-runner invoked'`nexit [int]`$env:FAKE_CR_EXIT`n")
        return $runner
    }
}

Describe 'Invoke-PrePublishGate step selection' {
    BeforeEach {
        $env:SNYK_TOKEN = '0' * 36   # synthetic; lets the snyk wrapper past its auth check
    }
    AfterEach {
        Remove-Item Env:SNYK_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_CR_EXIT -ErrorAction SilentlyContinue
        Remove-Item Env:CODERABBIT_RUNNER -ErrorAction SilentlyContinue
        Remove-Item Env:GATE_SHIM_LOG -ErrorAction SilentlyContinue
    }

    It 'skips lint/tests when the project has no recognized manifest' {
        $proj = New-GateProject 'empty' @{ 'readme.txt' = "hello`n" }
        $shims = New-ShimDir 'shims-empty' @('uv', 'npm', 'docker')
        $r = Invoke-Gate $proj $shims @()
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'no recognized project type'
        $r.Log | Should -BeNullOrEmpty
    }

    It 'runs ruff and pytest for a Python project' {
        $proj = New-GateProject 'py' @{ 'pyproject.toml' = "[project]`nname = `"x`"`n" }
        $shims = New-ShimDir 'shims-py' @('uv', 'docker')
        $r = Invoke-Gate $proj $shims @()
        $r.ExitCode | Should -Be 0
        $r.Log | Should -Match 'uv run --with ruff python -m ruff check'
        $r.Log | Should -Match 'pytest'
    }

    It 'skips pytest but keeps ruff with -SkipTests' {
        $proj = New-GateProject 'pyskip' @{ 'pyproject.toml' = "[project]`nname = `"x`"`n" }
        $shims = New-ShimDir 'shims-pyskip' @('uv', 'docker')
        $r = Invoke-Gate $proj $shims @('-SkipTests')
        $r.ExitCode | Should -Be 0
        $r.Log | Should -Match 'ruff check'
        $r.Log | Should -Not -Match 'pytest'
    }

    It 'runs npm test for a Node project' {
        $proj = New-GateProject 'node' @{ 'package.json' = "{`n  `"name`": `"x`"`n}`n" }
        $shims = New-ShimDir 'shims-node' @('npm', 'docker')
        $r = Invoke-Gate $proj $shims @()
        $r.ExitCode | Should -Be 0
        $r.Log | Should -Match 'npm test'
    }

    It 'builds docker when a Dockerfile exists, skips with -SkipDocker' {
        $proj = New-GateProject 'dock' @{ 'Dockerfile' = "FROM scratch`n" }
        $shims = New-ShimDir 'shims-dock' @('docker')
        $with = Invoke-Gate $proj $shims @()
        $with.ExitCode | Should -Be 0
        $with.Log | Should -Match 'docker build'
        $without = Invoke-Gate $proj $shims @('-SkipDocker')
        $without.ExitCode | Should -Be 0
        $without.Log | Should -Not -Match 'docker build'
    }

    It 'adds the snyk step with -WithSnyk (deps + SAST, no container)' {
        $proj = New-GateProject 'snyk' @{
            'pyproject.toml' = "[project]`nname = `"x`"`n"
            'Dockerfile'     = "FROM scratch`n"
        }
        $shims = New-ShimDir 'shims-snyk' @('uv', 'docker', 'snyk')
        $r = Invoke-Gate $proj $shims @('-WithSnyk', '-SkipTests', '-SkipDocker')
        $r.ExitCode | Should -Be 0
        $r.Log | Should -Match 'snyk test'
        $r.Log | Should -Match 'snyk code test'
        $r.Log | Should -Not -Match 'snyk container'
    }

    It 'omits the snyk step by default' {
        $proj = New-GateProject 'nosnyk' @{ 'pyproject.toml' = "[project]`nname = `"x`"`n" }
        $shims = New-ShimDir 'shims-nosnyk' @('uv', 'snyk')
        $r = Invoke-Gate $proj $shims @('-SkipTests')
        $r.ExitCode | Should -Be 0
        $r.Log | Should -Not -Match 'snyk'
    }

    It 'passes with -WithCodeRabbit when the runner exits 0' {
        $proj = New-GateProject 'cr0' @{ '.coderabbit.yaml' = "language: en-US`n" }
        $shims = New-ShimDir 'shims-cr0' @('docker')
        $env:CODERABBIT_RUNNER = New-FakeCodeRabbitRunner
        $env:FAKE_CR_EXIT = '0'
        $r = Invoke-Gate $proj $shims @('-WithCodeRabbit')
        $r.ExitCode | Should -Be 0
        $r.Log | Should -Match 'coderabbit-runner invoked'
    }

    It 'fails the gate when the runner reports findings (exit 2)' {
        $proj = New-GateProject 'cr2' @{ '.coderabbit.yaml' = "language: en-US`n" }
        $shims = New-ShimDir 'shims-cr2' @('docker')
        $env:CODERABBIT_RUNNER = New-FakeCodeRabbitRunner
        $env:FAKE_CR_EXIT = '2'
        $r = Invoke-Gate $proj $shims @('-WithCodeRabbit')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'exit code 2'
    }

    It 'continues with a warning when the runner defers (exit 3)' {
        $proj = New-GateProject 'cr3' @{ '.coderabbit.yaml' = "language: en-US`n" }
        $shims = New-ShimDir 'shims-cr3' @('docker')
        $env:CODERABBIT_RUNNER = New-FakeCodeRabbitRunner
        $env:FAKE_CR_EXIT = '3'
        $r = Invoke-Gate $proj $shims @('-WithCodeRabbit')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'deferred'
        $r.Output | Should -Match 'Pre-publish gate passed'
    }
}
