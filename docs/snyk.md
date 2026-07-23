# Snyk flow

Dependency, code (SAST), and container vulnerability scanning for any repo,
gated the same way everywhere: through `scripts/Invoke-SnykScan.ps1`.

## SNYK_TOKEN: user-level env var ONLY

The token authenticates every scan. It must never appear in a file, a log,
a doc, a fixture, a commit message, or review output.

1. Get a token: snyk.io → Account Settings → Auth Token.
2. Set it as a **user-level** environment variable (one time per machine):

   ```powershell
   [Environment]::SetEnvironmentVariable('SNYK_TOKEN', 'PASTE_TOKEN_HERE', 'User')
   ```

   Restart the shell afterwards. Bootstrap's env-var check does not set this
   one for you — it is a secret, not a default.
3. In CI, store it as a GitHub repo secret (`SNYK_TOKEN`) and expose it only
   through `env:` on the scan step (see `templates/github/snyk.yml`). Never
   `echo` it, never pass it as a CLI argument (arguments show up in logs).

The scanner reads `SNYK_TOKEN` from the process env, falling back to the
user-level value; it never prints or persists it.

## What to scan, when

| Scan | Command | Runs when | Catches |
| --- | --- | --- | --- |
| Dependencies | `snyk test` | A manifest exists (`package.json`, `pyproject.toml`, `requirements.txt`, `go.mod`, …) | Vulnerable/outdated third-party packages |
| Code (SAST) | `snyk code test` | Always (skip with `-SkipCode`) | Injection, unsafe APIs, hardcoded-secret-shaped code in first-party source |
| Container | `snyk container test` | A `Dockerfile` exists (skip with `-SkipContainer`) | OS-package vulnerabilities in the built image |

Cadence: run the full gate **before every publish** (wired into
`Invoke-PrePublishGate.ps1 -WithSnyk`), and in CI on push/PR via
`templates/github/snyk.yml`. Dependency scans also matter whenever a manifest
or lockfile changes.

## How results gate a publish

```powershell
pwsh -File D:\Projects\workbench\scripts\Invoke-SnykScan.ps1 -ProjectPath .
pwsh -File D:\Projects\workbench\scripts\Invoke-SnykScan.ps1 -ProjectPath . -SeverityThreshold critical -SkipContainer
```

Exit codes:

| Code | Meaning | Publish? |
| --- | --- | --- |
| 0 | No findings at/above the threshold | Yes |
| 1 | Findings at/above the threshold | **No** — fix, upgrade, or (rarely) add a justified `.snyk` ignore, then re-run |
| 2 | Scan failed or misconfigured (missing CLI, missing token, snyk/docker error) | **No** — fail closed. A scan that couldn't run is not a passing scan |

Default threshold is `high` (fail on high + critical). Tighten to `critical`
for noisy repos; loosen below `high` only with a written reason in the repo.

Container scans need an image: pass `-ContainerImage repo:tag` to scan an
existing one, or let the wrapper build `<dirname>:local` from the Dockerfile
(requires the docker CLI; without it the container scan is skipped with a
note, not failed).

## Installing the CLI

```powershell
winget install --id Snyk.Snyk --exact   # verified winget id
# or: npm install -g snyk
```

Bootstrap checks for the CLI and reports PASS/FIXED/MANUAL accordingly.
