# Restore-after-wipe checklist

Run after bootstrap on a rebuilt machine. Every box must be checkable before
doing real work.

- [ ] `git --version` works; `git config user.name` / `user.email` are correct
- [ ] `pwsh --version` is 7.x and `pwsh` resolves without a full path
- [ ] PowerShell profile loads without errors (open pwsh; look for warnings)
- [ ] Git Bash loads `~/.bashrc` (aliases `gs`, `gl` work)
- [ ] `uv --version` works
- [ ] `wsl -l -q` lists `Debian`; `wsl -d Debian -- git --version` works
- [ ] Docker Desktop is running and `docker version` shows both client and server
- [ ] pwsh: `Get-Module -ListAvailable Pester` returns a version
- [ ] `$env:CODERABBIT_RUNNER` points at an existing file (if using review gates)
- [ ] GitHub auth works: `git ls-remote https://github.com/ColterD/workbench.git`
- [ ] A Python project gates green: `Invoke-PrePublishGate.ps1 -ProjectPath <repo>`
- [ ] Secret scan runs: `Invoke-SecretScan.ps1 -Path <repo>` exits 0
