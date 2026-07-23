# workbench

My personal environment registry: shell config, git config, machine bootstrap,
reusable workflow scripts, project templates, and runbooks. Not just dotfiles —
everything needed to rebuild a working dev environment after a wipe or on a new
machine, without re-deriving hard-won setup knowledge.

## Layout

```text
bootstrap/   Install-Workbench.ps1 — idempotent machine provisioning + checks
shell/       PowerShell 7 profile, Git Bash .bashrc, shared aliases
git/         .gitconfig, global .gitignore
scripts/     Reusable gates: pre-publish checks, secret scan, CodeRabbit wrapper
templates/   AGENTS.md, Python/Docker/CI/dependabot starters for new projects
docs/        New-machine runbook, restore-after-wipe checklist, secrets policy
```

## Quickstart (new machine)

```powershell
# 1. Clone
git clone https://github.com/ColterD/workbench.git D:\Projects\workbench

# 2. Bootstrap (safe to re-run; prints a pass/fail checklist)
pwsh -ExecutionPolicy Bypass -File D:\Projects\workbench\bootstrap\Install-Workbench.ps1

# 3. Follow docs/restore-after-wipe.md for anything the checklist flags
```

## Rules

- **No secrets, ever.** Env var NAMES only; values live in user-level
  environment variables or local untracked files. See docs/secrets-policy.md.
  Every commit should survive `scripts/Invoke-SecretScan.ps1`.
- **Idempotent everything.** Any script here must be safe to re-run.
- **Reference, don't duplicate.** Central tools (e.g. the private CodeRabbit
  runner repo) are invoked by path/env var, never vendored in.
