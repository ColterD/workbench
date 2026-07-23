# workbench

[![ci](https://github.com/ColterD/workbench/actions/workflows/ci.yml/badge.svg)](https://github.com/ColterD/workbench/actions/workflows/ci.yml)

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

## Scripts

### bootstrap/Install-Workbench.ps1

Idempotent provisioning for a fresh or existing Windows machine. Verifies (and
where possible installs) Git, PowerShell 7, uv, Docker CLI, WSL Debian, and
Pester; sets user-level env var defaults; installs the shell profiles and git
config from this repo into `~`, backing up any existing file once to
`<name>.pre-workbench`. Ends with a pass/fix/manual/fail checklist and exits 1
on any FAIL. Safe to re-run.

```powershell
# Full run (installs what's missing)
pwsh -ExecutionPolicy Bypass -File bootstrap\Install-Workbench.ps1

# Check-only dry run — installs nothing, reports what would need action
pwsh -ExecutionPolicy Bypass -File bootstrap\Install-Workbench.ps1 -NoInstall
```

### scripts/Invoke-SecretScan.ps1

Pattern-based secret scan for a project directory. Covers tracked files and
untracked-non-ignored files (git-aware), or the whole tree outside a repo.
Exits 1 on any hit. Allowlist false positives with a literal value per line in
`<root>\.secret-scan-allow`. Run it before every commit.

```powershell
pwsh -File scripts\Invoke-SecretScan.ps1 -Path D:\Projects\some-repo
```

### scripts/Invoke-PrePublishGate.ps1

Generic pre-publish gate for a project: secret scan, then lint + tests (ruff +
pytest via `uv` for Python, `npm test` for Node — skipped when the project has
neither), then `docker build` when a Dockerfile exists and the Docker CLI is
available. Exits nonzero on the first failed step.

```powershell
# Full gate
pwsh -File scripts\Invoke-PrePublishGate.ps1 -ProjectPath D:\Projects\some-repo

# Skip the docker build and/or the test step
pwsh -File scripts\Invoke-PrePublishGate.ps1 -ProjectPath . -SkipDocker -SkipTests
```

### scripts/Invoke-CodeRabbitReview.ps1

Thin wrapper around the central quota-aware CodeRabbit runner (private repo,
located via the `CODERABBIT_RUNNER` env var). Reviews a repo's uncommitted
changes; requires a `.coderabbit.yaml` in the target repo and PowerShell 7
(relaunches itself under pwsh when invoked from 5.1). Exit codes: 0 = clean,
2 = critical/major findings, 3 = deferred by quota/replay policy, anything
else = review failed. Never reimplements runner logic — quota, replay, and CLI
invocation live in the central runner only.

```powershell
pwsh -File scripts\Invoke-CodeRabbitReview.ps1 -Repository D:\Projects\some-repo
pwsh -File scripts\Invoke-CodeRabbitReview.ps1 -Repository . -TaskId "my-feature-review"
```

## Quick reference

| Tool | Path | Purpose | Key flags |
| --- | --- | --- | --- |
| Bootstrap | `bootstrap/Install-Workbench.ps1` | Provision/verify machine; install profiles + git config | `-NoInstall` (check only) |
| Secret scan | `scripts/Invoke-SecretScan.ps1` | Regex secret scan, allowlist via `.secret-scan-allow` | `-Path` (required) |
| Pre-publish gate | `scripts/Invoke-PrePublishGate.ps1` | secret scan → lint → tests → docker build | `-SkipDocker`, `-SkipTests` |
| CodeRabbit review | `scripts/Invoke-CodeRabbitReview.ps1` | Invoke central runner on uncommitted changes | `-TaskId`, `-Runner` |

## Adopting workbench in a new project

1. **Copy the templates** that match the project:
   - `templates/AGENTS.md` → repo root (conventions for agent sessions)
   - `templates/Dockerfile.python-uv` → `Dockerfile` (Python/uv projects)
   - `templates/github/ci.yml` → `.github/workflows/ci.yml`
   - `templates/github/dependabot.yml` → `.github/dependabot.yml`
2. **Call the gates from the project's own automation** instead of copying
   them — reference workbench by path so fixes propagate:
   ```powershell
   pwsh -File D:\Projects\workbench\scripts\Invoke-SecretScan.ps1 -Path .
   pwsh -File D:\Projects\workbench\scripts\Invoke-PrePublishGate.ps1 -ProjectPath .
   ```
3. **Opt into CodeRabbit** by adding a `.coderabbit.yaml` at the repo root,
   then reviewing via `Invoke-CodeRabbitReview.ps1`. The central runner is the
   only invocation owner; never call the CodeRabbit CLI directly.
4. **Keep secrets out**: env var names only in tracked files; values in
   user-level env vars or untracked local files. See docs/secrets-policy.md.

## Rules

- **No secrets, ever.** Env var NAMES only; values live in user-level
  environment variables or local untracked files. See docs/secrets-policy.md.
  Every commit should survive `scripts/Invoke-SecretScan.ps1`.
- **Idempotent everything.** Any script here must be safe to re-run.
- **Reference, don't duplicate.** Central tools (e.g. the private CodeRabbit
  runner repo) are invoked by path/env var, never vendored in.
