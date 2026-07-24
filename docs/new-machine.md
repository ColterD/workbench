# New machine runbook

Order matters; each step unblocks later ones.

1. **Install Git** (`winget install Git.Git`) and clone this repo to
   `D:\Projects\workbench`. Projects convention: everything under `D:\Projects`.
2. **Run the bootstrap**: `pwsh -ExecutionPolicy Bypass -File
   D:\Projects\workbench\bootstrap\Install-Workbench.ps1`. Re-run freely; it is
   idempotent and ends with a pass/fail checklist.
3. **Restart all shells** after the bootstrap so user-level PATH and env vars
   (`DOCKER_CONFIG`, `CODERABBIT_RUNNER`) load.
4. **WSL Debian** if the checklist flags it: `wsl --install -d Debian`, reboot,
   then finish distro setup (user, git).
5. **Docker Desktop**: install and start it; the bootstrap adds a standalone
   CLI pointing at the running daemon with a credential-helper-free config.
6. **Secrets** (never in this repo — see secrets-policy.md):
   - Vault layer (canonical): set `VAULT_ADDR` (your OpenBao/Vault address —
     local-only, never committed) and `VAULT_TOKEN`, then run
     `pwsh -File D:\Projects\workbench\scripts\Sync-Secrets.ps1` to pull the
     inventory into user-level env vars. See docs/secrets-inventory.md.
   - Anything not in the vault (`CODERABBIT_TASK_ID` as needed): user-level
     env vars by hand.
   - GitHub auth: `gh auth login` or the credential manager of choice.
7. **Central tools**: clone the private CodeRabbit runner
   (`ColterD/coderabbit`) to `D:\Projects\coderabbit` if this machine will run
   review gates.
8. **Verify**: run the restore-after-wipe checklist end to end.
