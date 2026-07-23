# Pre-publish gate

One command before every publish: `scripts/Invoke-PrePublishGate.ps1`.
It runs the steps a project has, skips the ones it does not, and exits
nonzero on the first failure.

## Recommended full gate order

```text
secret scan  →  lint  →  tests  →  snyk  →  docker build  →  coderabbit
```

Why this order:

1. **Secret scan** — cheapest check, catches the unfixable-by-rewrite class
   (a leaked secret means rotation, not just a revert). Fail in seconds.
2. **Lint** — next cheapest; no point testing code that does not parse.
3. **Tests** — correctness before spending on slower external steps.
4. **Snyk** — dependency + SAST findings block a publish; runs before the
   image build so you do not build artifacts from already-rejected code.
5. **Docker build** — slowest local step; proves the Dockerfile still
   produces an image.
6. **CodeRabbit** — the human-review substitute; runs last so it reviews
   the exact diff that passed everything else (and its quota is only spent
   on changes worth reviewing).

## Usage

```powershell
# Default: secret scan -> lint -> tests -> docker build
pwsh -File D:\Projects\workbench\scripts\Invoke-PrePublishGate.ps1 -ProjectPath .

# Full gate
pwsh -File D:\Projects\workbench\scripts\Invoke-PrePublishGate.ps1 -ProjectPath . -WithSnyk -WithCodeRabbit
```

| Flag | Effect |
| --- | --- |
| `-SkipDocker` | Skip the docker build step |
| `-SkipTests` | Skip pytest/npm test (lint still runs) |
| `-WithSnyk` | Insert `Invoke-SnykScan.ps1 -SkipContainer` after tests (deps + SAST; container scans need a built image — run `Invoke-SnykScan.ps1` directly against the image when publishing containers) |
| `-WithCodeRabbit` | Run `Invoke-CodeRabbitReview.ps1` last |

Exit behavior:

- Any step failing (lint, tests, snyk findings or errors, docker build)
  aborts the gate nonzero immediately.
- CodeRabbit exit 2 (critical/major findings) or 4 (failure) fails the gate;
  exit 3 (deferred by quota/replay policy) is a warning — the gate continues,
  because a deferral says nothing about the diff.
- Prerequisites are per-tool: snyk needs the CLI + `SNYK_TOKEN`
  (docs/snyk.md), CodeRabbit needs `.coderabbit.yaml` + `CODERABBIT_RUNNER`
  (docs/coderabbit.md). Missing prerequisites fail closed.

## Standalone optional gate: ASCII scan

`scripts/Invoke-AsciiScan.ps1` fails (exit 1) when any scanned source file
contains non-ASCII characters (smart quotes, mojibake), listing the
offending lines. It is deliberately NOT part of the pre-publish gate — most
projects legitimately carry non-ASCII content somewhere — so run it
directly or from CI when a codebase should stay pure ASCII:

```powershell
# Defaults: scans ./src for *.ts
pwsh -File D:\Projects\workbench\scripts\Invoke-AsciiScan.ps1

# Explicit directories and extensions
pwsh -File D:\Projects\workbench\scripts\Invoke-AsciiScan.ps1 -Path src, scripts -Extensions ts, ps1
```
