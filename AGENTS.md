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
|-- scripts/     # Gates: secret scan, pre-publish, CodeRabbit + Snyk wrappers,
|                # Context7 state scrub, ASCII scan (standalone)
|-- templates/   # AGENTS.md, Dockerfile.python-uv, .coderabbit.yaml, CI/dependabot/snyk,
|                # .gitattributes/.editorconfig/pre-commit/renovate starters
|-- tests/       # Pester 5 suite (scanner, gate step-selection, bootstrap -NoInstall,
|                # Context7 state scrub)
|-- docs/        # Runbooks + policies: new-machine, restore-after-wipe,
|                # secrets-policy, coderabbit, snyk, pre-publish-gate,
|                # context7-state-scrub, openbao-cutover
|-- .secret-scan-allow  # Allowlist example (synthetic entries only)
`-- AGENTS.md
```

## WHERE TO LOOK

| Task | Location | Notes |
| --- | --- | --- |
| Machine provisioning | `bootstrap/Install-Workbench.ps1` | Ends with pass/fix/manual/fail checklist; exit 1 on any FAIL. `-NoInstall` is check-only and never writes state. |
| Secret scanning | `scripts/Invoke-SecretScan.ps1` | Named regex patterns + `.secret-scan-allow` literal allowlist (`#` comments ok). `-Staged` scans index blobs for pre-commit. |
| Pre-publish gate | `scripts/Invoke-PrePublishGate.ps1` | secret scan → ruff+pytest via `uv run --with` → docker build. Opt-ins: `-WithSnyk`, `-WithCodeRabbit`. Order rationale: `docs/pre-publish-gate.md`. |
| CodeRabbit reviews | `scripts/Invoke-CodeRabbitReview.ps1` | Thin wrapper; NEVER reimplement runner logic here. Flow + exit codes 0/2/3/4: `docs/coderabbit.md`. |
| Snyk scanning | `scripts/Invoke-SnykScan.ps1` | deps + SAST + container from project layout; exit 0/1/2 fail-closed. `SNYK_TOKEN` user env var ONLY: `docs/snyk.md`. |
| Context7 state scrub | `scripts/Invoke-Context7StateScrub.ps1` | Audit/Scrub ctx7sk keys in Codex state; fingerprints only, atomic writes, fail-closed. Requires pwsh 7 + rg: `docs/context7-state-scrub.md`. |
| ASCII scan | `scripts/Invoke-AsciiScan.ps1` | Standalone optional gate (NOT in the pre-publish gate): exit 1 on non-ASCII in source files. Defaults `./src` + `ts`; `-Path`/`-Extensions` override. |
| Tests | `tests/` | Pester 5.x; external tools shim-mocked. Wired into CI (windows-latest job). |
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
- Locals that differ from a parameter only by case: PowerShell variables are
  case-insensitive, so `$staged = ...` rebinds a `[switch]$Staged` parameter
  (and typed params throw on the cast). Rename the local.

## COMMANDS

```powershell
# Syntax-check a script (from pwsh)
[void][System.Management.Automation.Language.Parser]::ParseFile('<path>', [ref]$null, [ref]$errs)

# Secret scan (add -Staged for pre-commit use)
pwsh -File scripts/Invoke-SecretScan.ps1 -Path .

# Pre-publish gate (full: add -WithSnyk -WithCodeRabbit)
pwsh -File scripts/Invoke-PrePublishGate.ps1 -ProjectPath .

# Test suite (Pester 5.x)
Invoke-Pester -Path tests

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
