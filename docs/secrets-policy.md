# Secrets policy

This repo is structured so it can never hold a secret. Keep it that way.

## Rules

1. **No secret values in tracked files.** Not in examples, not "temporarily",
   not in tests. Use placeholders (`change-this`, `YOUR_TOKEN_HERE`) or
   synthetic fixtures (e.g. `ghp_` + 30 x's).
2. **Env var names are fine; values are not.** Document the NAME
   (`SNYK_TOKEN`, `CODERABBIT_TASK_ID`) and set the value as a user-level
   environment variable or in a local untracked file.
3. **Local overrides stay local.** `$PROFILE.local.ps1`, `~/.bashrc.local`,
   `.env`, and `*.local` are covered by the global gitignore and must never be
   committed anywhere.
4. **Scan before trusting.** `scripts/Invoke-SecretScan.ps1` runs in the
   pre-publish gate and should pass on every repo, including this one. Add
   false positives to `.secret-scan-allow` (literal values), never by weakening
   the patterns.
5. **If a secret ever lands in a commit**: rotate it immediately, then scrub
   history. Deleting the file in a later commit is not enough.

## What the scanner catches

`scripts/Invoke-SecretScan.ps1` pattern-matches, grouped:

- **Generic/structural**: credential assignments (`api_key = "..."`),
  private-key blocks, `Bearer` values, JWTs, credentials embedded in URIs
  (the `user:password@host` form), kubeconfig `client-key-data`, Azure
  `AccountKey=`, age secret keys
- **Git platforms**: GitHub PATs (`ghp_`, `github_pat_`, `gho_`/`ghu_`/
  `ghs_`/`ghr_`), GitLab (`glpat-`, runner `glrt-`, CI job `glcbt-`)
- **AI providers**: OpenAI (`sk-`, `sk-proj-`), Anthropic (`sk-ant-`),
  Hugging Face (`hf_`), Groq (`gsk_`), Replicate (`r8_`)
- **Cloud/infra**: AWS access key IDs (`AKIA...`), DigitalOcean, Docker Hub,
  Supabase, PlanetScale, Neon, Doppler
- **Payments**: Stripe (`sk_live_`/`rk_live_` + test variants), Square
- **Package registries**: npm (`npm_`), PyPI (`pypi-`)
- **Comms/webhooks**: Slack tokens and webhook URLs, Discord webhook URLs,
  Telegram bot tokens, SendGrid, Twilio
- **SaaS**: Google API keys (`AIza...`), Google OAuth client secrets
  (`GOCSPX-`), Shopify, New Relic (`NRAK-`), Okta (`SSWS`), Linear, Notion,
  Figma, Airtable, Snyk UATs

Hit output names the pattern so you can tell what it thinks it found.

Two run modes:

- **Full scan** (default): tracked + untracked-non-ignored files (git-aware),
  or the whole tree outside a repo.
- **Staged scan** (`-Staged`): only blobs in the git index, read via
  `git show` — exactly what a commit would contain. Wire this into a
  pre-commit hook: `pwsh -File <path-to>\Invoke-SecretScan.ps1 -Path . -Staged`.

## Handling false positives

Patterns err toward flagging. When a hit is a known non-secret (doc example,
synthetic fixture, public identifier):

1. Copy `.secret-scan-allow` from this repo into the target repo root if it
   is not there yet.
2. Add the full matched value, one literal per line. Blank lines and lines
   starting with `#` are ignored — use them to justify each entry.
3. A hit is suppressed when the match CONTAINS an allowlisted value, so keep
   entries long enough to stay specific (a short substring would suppress
   unrelated real secrets).
4. NEVER allowlist a real credential. If it was ever real, rotate it, scrub
   it, then — if the rotated-out string must remain visible in docs —
   allowlist the dead value with a comment saying so.
5. NEVER "fix" a false positive by weakening a pattern. The allowlist is the
   only sanctioned escape hatch.

## Where secrets legitimately live

| Kind | Location |
| --- | --- |
| API tokens (Snyk, GitHub, etc.) | User-level env vars (`[Environment]::SetEnvironmentVariable(..., 'User')`) |
| Shell-specific overrides | `$PROFILE.local.ps1`, `~/.bashrc.local` |
| Per-project secrets | `.env` in the project root (gitignored globally) |
| CI secrets | GitHub repo → Settings → Secrets and variables |
