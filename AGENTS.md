# PROJECT KNOWLEDGE BASE

## OVERVIEW

Workbench is my personal tooling layer ("dotfiles-plus"): machine bootstrap,
shell configs, git config, reusable gate scripts, project templates, and setup
runbooks — everything needed to rebuild a working dev environment after a wipe
or on a new machine. It is personal infrastructure, not a product: keep it
small, idempotent, and free of anything machine-specific that belongs in local
overrides.

## STRUCTURE

```text
./
|-- bootstrap/   # Install-Workbench.ps1 — idempotent provisioning + checklist
|-- shell/       # PowerShell 7 profile, Git Bash .bashrc
|-- git/         # .gitconfig, .gitignore-global (installed to ~ by bootstrap)
|-- scripts/     # Gates: secret scan, pre-publish, CodeRabbit wrapper
|-- templates/   # AGENTS.md, Dockerfile.python-uv, CI, dependabot starters
|-- docs/        # new-machine.md, restore-after-wipe.md, secrets-policy.md
`-- AGENTS.md
```

## WHERE TO LOOK

| Task | Location | Notes |
| --- | --- | --- |
| Machine provisioning | `bootstrap/Install-Workbench.ps1` | Ends with pass/fix/manual/fail checklist; exit 1 on any FAIL. |
| Secret scanning | `scripts/Invoke-SecretScan.ps1` | Regex patterns + `.secret-scan-allow` literal allowlist. |
| Pre-publish gate | `scripts/Invoke-PrePublishGate.ps1` | Secret scan → ruff+pytest via `uv run --with` → docker build. |
| CodeRabbit reviews | `scripts/Invoke-CodeRabbitReview.ps1` | Thin wrapper; NEVER reimplement runner logic here. |
| What a fresh machine needs | `docs/new-machine.md` | Ordered; each step unblocks later ones. |

## CONVENTIONS

- **No secrets, ever.** Env var NAMES only in tracked files; values live in
  user-level env vars or local untracked overrides (`$PROFILE.local.ps1`,
  `~/.bashrc.local`, `.env`). Every commit must survive
  `scripts/Invoke-SecretScan.ps1`. See `docs/secrets-policy.md`.
- **Idempotent everything.** Any script here must be safe to re-run; check
  before changing, back up before overwriting (`.pre-workbench` suffix, once).
- **Reference, don't duplicate.** Central tools (the private CodeRabbit runner
  at `D:\Projects\coderabbit\Invoke-CodeRabbit.ps1`, reached via
  `CODERABBIT_RUNNER`) are invoked by path/env var, never vendored in.
- Shell scripts target PowerShell 7 but degrade gracefully on 5.1 where noted
  (e.g. the CodeRabbit wrapper re-launches under pwsh).
- Docs must match what scripts actually do; a checklist item in
  `docs/restore-after-wipe.md` implies a bootstrap check that produces it.
- Git identity for this repo: `ColterD` /
  `29168599+ColterD@users.noreply.github.com` (comes from `git/.gitconfig`
  once installed; pass `-c user.name=... -c user.email=...` before then).

## ANTI-PATTERNS

- Secret values in logs, docs, fixtures, templates, or review output —
  including "example" tokens that are real. Placeholders and synthetic
  fixtures only; false positives go in `.secret-scan-allow`, never by
  weakening scan patterns.
- Vendoring or reimplementing the central CodeRabbit runner.
- Non-idempotent bootstrap steps, or overwriting user files without a backup.
- Machine-specific paths/hostnames in tracked files outside the documented
  `D:\Projects` convention; everything else belongs in local overrides.
- PowerShell syntax checks that pass the script path as a trailing argument to
  `pwsh -Command` — trailing args get joined into the command and can EXECUTE
  the script. Embed the path inside the command string or use `-File` on a
  checker script.

## COMMANDS

```powershell
# Syntax-check a script (from pwsh)
[void][System.Management.Automation.Language.Parser]::ParseFile('<path>', [ref]$null, [ref]$errs)

# Secret scan
pwsh -File scripts/Invoke-SecretScan.ps1 -Path .

# Bootstrap (idempotent; -NoInstall for check-only dry run)
pwsh -ExecutionPolicy Bypass -File bootstrap/Install-Workbench.ps1
pwsh -ExecutionPolicy Bypass -File bootstrap/Install-Workbench.ps1 -NoInstall
```

## REVIEW GUIDELINES

Blocking findings for reviewers (human or AI):

- Any real-looking secret value in a tracked file.
- Bootstrap steps that are not idempotent or overwrite without backup.
- CodeRabbit runner logic duplicated instead of invoked via CODERABBIT_RUNNER.
- Docs/checklists that describe behavior the scripts do not implement.
- Scripts that fail on PowerShell 5.1 without a documented graceful path.
