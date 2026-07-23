# CodeRabbit review flow

Local, quota-aware CodeRabbit reviews for any repo under `D:\Projects`.
There is exactly ONE way to run a review: through the central runner.
Everything else — including this repo's wrapper — only locates and invokes it.

## The one rule

**The central runner is the only invocation owner.**

`D:\Projects\coderabbit\Invoke-CodeRabbit.ps1` (private repo, located via the
`CODERABBIT_RUNNER` user-level env var set by bootstrap) owns quota
accounting, replay, WSL/CLI invocation, and output handling. Never:

- call the CodeRabbit CLI directly,
- re-implement quota/replay logic in a repo script,
- vendor a copy of the runner into another repo.

Repo-level entry point (thin wrapper, path/env resolution + pwsh 7 relaunch
only):

```powershell
pwsh -File D:\Projects\workbench\scripts\Invoke-CodeRabbitReview.ps1 -Repository D:\Projects\some-repo
pwsh -File D:\Projects\workbench\scripts\Invoke-CodeRabbitReview.ps1 -Repository . -TaskId "my-feature-review"
```

## Opting a repo in

1. Copy `templates/.coderabbit.yaml` from this repo to the target repo's
   root, adjust `path_filters` / `path_instructions`, and commit it.
2. That's it. The wrapper requires the config at the repo root and passes it
   to the runner; the runner requires that repo and config both resolve
   beneath `D:\Projects`.

The config is hashed into the review fingerprint, so editing it intentionally
triggers a fresh (non-replayed) review of the same diff.

## When to run

- Before committing a coherent chunk of work (the wrapper reviews
  **uncommitted** changes: tracked modifications + non-ignored untracked
  files, snapshotted via a private temporary git index — your real index is
  untouched).
- After addressing findings, run again with the **same task id** — see
  replay below.
- As the final step of the pre-publish gate (order: secret scan → lint →
  tests → snyk → docker build → coderabbit).

## Quota and replay policy

The runner protects a shared review quota with three guards; any of them can
defer a review (exit 3):

- **Rolling-hour guard** — caps total reviews in a sliding window.
- **Per-task guard** — caps reviews under one task identity.
- **Lock guard** — prevents concurrent reviews stomping each other.

**Replay:** a stable task identity (`CODERABBIT_TASK_ID`, set by the wrapper
from `-TaskId`, default `manual-review-<date>`) plus a diff fingerprint
(base/head commits + diff hash + config hash). Repeating a review with the
same identity and an unchanged diff reads the CLI's locally retained findings
instead of starting a new analysis — free re-checks of "did I fix it" without
spending quota. Changed diff or changed config = fresh analysis.

The runner persists only hashes, version identifiers, timestamps, and quota
counters — never findings, patches, prompts, or raw CLI output.
Secret-bearing paths fail validation before the CLI is ever started.

## Exit codes

| Code | Meaning | What to do |
| --- | --- | --- |
| 0 | Clean — no critical/major findings, or no changes | Proceed. |
| 2 | Critical/major findings reported | Resolve them, then re-run with the same `-TaskId` (replay is free while the diff is unchanged; your fixes change the diff, so the re-run is a real review). |
| 3 | Deferred by rolling-hour / per-task / lock guard | Not a failure. Wait for the window to pass or the lock to clear; re-run later with the same `-TaskId`. Don't retry in a tight loop. |
| 4 | Validation, infrastructure, CLI, timeout, or incomplete-output failure | Read the NDJSON event on stdout (`reason`, `errorType`). Common causes: repo or config outside `D:\Projects`, missing task identity, secret-bearing path in the diff, CLI/WSL problem. Fix the cause; re-running unchanged just fails again. |

Any other non-zero CLI exit is normalized to 4 (fail closed).

## Requirements checklist

- Repo and `.coderabbit.yaml` beneath `D:\Projects` (canonical paths).
- `CODERABBIT_RUNNER` set (bootstrap does this) or pass `-Runner`.
- PowerShell 7 available — the wrapper relaunches itself under pwsh when
  invoked from 5.1.
- WSL Debian running (the CLI executes there); bootstrap checks this.
