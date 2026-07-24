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
scripts/     Reusable gates: secret scan, pre-publish, CodeRabbit + Snyk wrappers,
             Context7 state scrub, ASCII scan, vault secrets sync
templates/   AGENTS.md, .coderabbit.yaml, Python/Docker/CI/dependabot/snyk starters,
             .gitattributes/.editorconfig/pre-commit/renovate starters
tests/       Pester 5 suite (runs in CI on windows-latest)
docs/        Runbooks + policies: new-machine, restore-after-wipe, secrets,
             coderabbit, snyk, pre-publish gate, context7 state scrub,
             openbao cutover, secrets inventory
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

Pattern-based secret scan for a project directory: 50+ named patterns covering
generic credential assignments (env-style and quoted-key JSON/YAML forms),
Authorization and Cookie/Set-Cookie header values, GitHub/GitLab tokens, AI
providers (OpenAI/Anthropic/other `sk-` keys/Hugging Face/Groq/Replicate),
cloud/infra (AWS key IDs + presigned URL parameters, DigitalOcean,
Docker Hub, Supabase, PlanetScale, Neon, Doppler, Azure, kubeconfig), payments
(Stripe, Square), package registries (npm, PyPI), comms/webhooks (Slack,
Discord, Telegram, SendGrid, Twilio), SaaS (Google, Shopify, New Relic,
Okta, Linear, Notion, Figma, Airtable, Snyk), and Mega.nz link keys — plus
JWTs, private keys, Bearer values, and URI-embedded credentials. Full list:
docs/secrets-policy.md.
Covers tracked files and untracked-non-ignored files (git-aware), or the whole
tree outside a repo. Exits 1 on any hit. Allowlist false positives with a
literal value per line in `<root>\.secret-scan-allow` (`#` comments supported).
Run it before every commit.

```powershell
# Full scan
pwsh -File scripts\Invoke-SecretScan.ps1 -Path D:\Projects\some-repo

# Pre-commit: scan only staged blobs (content comes from the git index)
pwsh -File scripts\Invoke-SecretScan.ps1 -Path . -Staged
```

### scripts/Invoke-PrePublishGate.ps1

Generic pre-publish gate for a project: secret scan, then lint + tests (ruff +
pytest via `uv` for Python, `npm test` for Node — skipped when the project has
neither), then `docker build` when a Dockerfile exists and the Docker CLI is
available. Exits nonzero on the first failed step. Opt-in steps: `-WithSnyk`
inserts deps + SAST after tests; `-WithCodeRabbit` runs the central review
last (exit 3 quota-deferral warns without failing). Recommended full order and
exit behavior: docs/pre-publish-gate.md.

```powershell
# Full gate
pwsh -File scripts\Invoke-PrePublishGate.ps1 -ProjectPath D:\Projects\some-repo

# Skip the docker build and/or the test step
pwsh -File scripts\Invoke-PrePublishGate.ps1 -ProjectPath . -SkipDocker -SkipTests

# Everything: secret scan -> lint -> tests -> snyk -> docker -> coderabbit
pwsh -File scripts\Invoke-PrePublishGate.ps1 -ProjectPath . -WithSnyk -WithCodeRabbit
```

### scripts/Invoke-CodeRabbitReview.ps1

Thin wrapper around the central quota-aware CodeRabbit runner (private repo,
located via the `CODERABBIT_RUNNER` env var). Reviews a repo's uncommitted
changes; requires a `.coderabbit.yaml` in the target repo and PowerShell 7
(relaunches itself under pwsh when invoked from 5.1). Exit codes: 0 = clean,
2 = critical/major findings, 3 = deferred by quota/replay policy, 4 =
validation/infra/CLI failure. Never reimplements runner logic — quota,
replay, and CLI invocation live in the central runner only. Full flow:
docs/coderabbit.md; starter config: templates/.coderabbit.yaml.

```powershell
pwsh -File scripts\Invoke-CodeRabbitReview.ps1 -Repository D:\Projects\some-repo
pwsh -File scripts\Invoke-CodeRabbitReview.ps1 -Repository . -TaskId "my-feature-review"
```

### scripts/Invoke-SnykScan.ps1

Reusable Snyk gate: dependency scan when a manifest exists, SAST
(`snyk code test`) by default, and a container scan when a Dockerfile exists
(builds `<dirname>:local` via docker, or pass `-ContainerImage`). Fails at or
above a configurable severity threshold (default `high`) and fails CLOSED on
scan errors or misconfiguration. Reads `SNYK_TOKEN` from the process or
user-level env var — never from a file, never echoed. Exit codes: 0 = clean,
1 = findings, 2 = scan failed/misconfigured. See docs/snyk.md.

```powershell
pwsh -File scripts\Invoke-SnykScan.ps1 -ProjectPath D:\Projects\some-repo
pwsh -File scripts\Invoke-SnykScan.ps1 -ProjectPath . -SeverityThreshold critical -SkipContainer
```

### scripts/Invoke-Context7StateScrub.ps1

Audit or scrub Context7 API keys (`ctx7sk-...`) out of local Codex state —
`.codex-global-state.json` (and its `.bak`) plus `rollout-*.jsonl`
transcripts under `sessions/` and `archived_sessions/`. Audit (default)
changes nothing; Scrub redacts keys in place
(`[REDACTED_CONTEXT7_KEY:<fingerprint>]`) and re-verifies zero remaining
occurrences. Key values are never printed or written anywhere — the JSON
report carries counts and 12-character SHA-256 fingerprints only. Every
target is validated before any is modified; writes are atomic and preserve
BOM, line endings, timestamps, attributes, and ACLs; reparse points and
UNC/device paths are rejected. Idempotent and fail-closed. Requires
PowerShell 7 + ripgrep. See docs/context7-state-scrub.md.

```powershell
# Audit: report occurrences, change nothing
pwsh -File scripts\Invoke-Context7StateScrub.ps1

# Scrub, closing and relaunching the Codex GUI around the write
pwsh -File scripts\Invoke-Context7StateScrub.ps1 -Mode Scrub -CloseAndRelaunchCodex
```

### scripts/Invoke-AsciiScan.ps1

Standalone optional ASCII gate: exits 1 when any scanned source file
contains non-ASCII characters (smart quotes, mojibake), listing the
offending lines. Byte-exact detection (Latin-1 read, same semantics as
`grep -P '[^\x00-\x7F]'`). Read-only and idempotent. Deliberately NOT part
of the pre-publish gate — call it directly or from CI for codebases that
should stay pure ASCII.

```powershell
# Defaults: scans ./src for *.ts
pwsh -File scripts\Invoke-AsciiScan.ps1

# Explicit directories and extensions
pwsh -File scripts\Invoke-AsciiScan.ps1 -Path src, scripts -Extensions ts, ps1
```

### scripts/Sync-Secrets.ps1

Sync secrets from OpenBao/Vault into Windows user-level environment
variables, driven by `scripts/sync-secrets.map.json` — an inventory of env
var NAMES → vault kv paths + keys, never values. `-Check` reports
SET/MISSING per entry plus vault reachability and always exits 0. Apply
mode is idempotent (in-sync entries untouched), supports `-WhatIf`, and
degrades gracefully (warning + exit 0) when `VAULT_ADDR`/`VAULT_TOKEN` are
missing or the vault is unreachable; exit 1 means at least one entry
actually failed to apply (failures are isolated per entry). Prefers the
`bao`/`vault` CLI, falls back to plain kv-v2 REST. Values flow vault →
env var only — never printed, logged, or persisted. Full model:
docs/secrets-inventory.md.

```powershell
pwsh -File scripts\Sync-Secrets.ps1 -Check
pwsh -File scripts\Sync-Secrets.ps1            # apply: pull + set user env vars
pwsh -File scripts\Sync-Secrets.ps1 -WhatIf
```

## Quick reference

| Tool | Path | Purpose | Key flags |
| --- | --- | --- | --- |
| Bootstrap | `bootstrap/Install-Workbench.ps1` | Provision/verify machine; install profiles + git config | `-NoInstall` (check only) |
| Secret scan | `scripts/Invoke-SecretScan.ps1` | Regex secret scan, allowlist via `.secret-scan-allow` | `-Path` (required), `-Staged` |
| Pre-publish gate | `scripts/Invoke-PrePublishGate.ps1` | secret scan → lint → tests → docker build | `-SkipDocker`, `-SkipTests`, `-WithSnyk`, `-WithCodeRabbit` |
| CodeRabbit review | `scripts/Invoke-CodeRabbitReview.ps1` | Invoke central runner on uncommitted changes | `-TaskId`, `-Runner` |
| Snyk scan | `scripts/Invoke-SnykScan.ps1` | deps + SAST + container vulns, fail-closed | `-SeverityThreshold`, `-SkipCode`, `-SkipContainer` |
| Context7 state scrub | `scripts/Invoke-Context7StateScrub.ps1` | Audit/Scrub ctx7sk keys in Codex state; fingerprints only | `-Mode`, `-CodexHome`, `-CloseAndRelaunchCodex` |
| ASCII scan | `scripts/Invoke-AsciiScan.ps1` | Standalone gate: exit 1 on non-ASCII in source files | `-Path`, `-Extensions` |
| Secrets sync | `scripts/Sync-Secrets.ps1` | Vault → user env var sync from a values-free map | `-Check`, `-WhatIf`, `-MapPath` |

## Adopting workbench in a new project

1. **Copy the templates** that match the project:
   - `templates/AGENTS.md` → repo root (conventions for agent sessions)
   - `templates/Dockerfile.python-uv` → `Dockerfile` (Python/uv projects)
   - `templates/github/ci.yml` → `.github/workflows/ci.yml`
   - `templates/github/dependabot.yml` → `.github/dependabot.yml`
   - `templates/.gitattributes` → repo root (LF default, CRLF for Windows scripts)
   - `templates/.editorconfig` → repo root (indent/charset/final-newline rules)
   - `templates/.pre-commit-config.yaml` → repo root (gitleaks + whitespace hygiene)
   - `templates/renovate.json` → repo root (automerge minor/patch, major-bump gate)
   - `.secret-scan-allow` → repo root (false-positive allowlist for the scan)
2. **Call the gates from the project's own automation** instead of copying
   them — reference workbench by path so fixes propagate:
   ```powershell
   pwsh -File D:\Projects\workbench\scripts\Invoke-SecretScan.ps1 -Path .
   pwsh -File D:\Projects\workbench\scripts\Invoke-PrePublishGate.ps1 -ProjectPath .
   ```
3. **Opt into CodeRabbit** — if the repo already has a `.coderabbit.yaml`,
   keep it; otherwise copy `templates/.coderabbit.yaml` to the repo root and
   commit it. Then review via `Invoke-CodeRabbitReview.ps1`. The central
   runner is the only invocation owner; never call the CodeRabbit CLI
   directly. See docs/coderabbit.md.
4. **Opt into Snyk** by setting `SNYK_TOKEN` as a user-level env var (CI:
   repo secret + `templates/github/snyk.yml`), then gate with
   `Invoke-SnykScan.ps1`. The token never goes in any file. See docs/snyk.md.
5. **Keep secrets out**: env var names only in tracked files; values in
   user-level env vars or untracked local files — or in the vault, synced
   by `Sync-Secrets.ps1` (docs/secrets-inventory.md). See
   docs/secrets-policy.md.

## Rules

- **No secrets, ever.** Env var NAMES only; values live in user-level
  environment variables or local untracked files. See docs/secrets-policy.md.
  Every commit should survive `scripts/Invoke-SecretScan.ps1`.
- **Idempotent everything.** Any script here must be safe to re-run.
- **Reference, don't duplicate.** Central tools (e.g. the private CodeRabbit
  runner repo) are invoked by path/env var, never vendored in.
