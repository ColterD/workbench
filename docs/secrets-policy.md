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

## Where secrets legitimately live

| Kind | Location |
| --- | --- |
| API tokens (Snyk, GitHub, etc.) | User-level env vars (`[Environment]::SetEnvironmentVariable(..., 'User')`) |
| Shell-specific overrides | `$PROFILE.local.ps1`, `~/.bashrc.local` |
| Per-project secrets | `.env` in the project root (gitignored globally) |
| CI secrets | GitHub repo → Settings → Secrets and variables |
