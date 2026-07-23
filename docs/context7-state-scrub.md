# Context7 state scrub

`scripts/Invoke-Context7StateScrub.ps1` finds Context7 API keys
(`ctx7sk-...`) that the Codex CLI persists in local state and redacts them
in place. Codex stores keys in `.codex-global-state.json` (and its `.bak`)
and in `rollout-*.jsonl` session transcripts under `sessions/` and
`archived_sessions/` — rotating the key does not remove those local copies,
so this script exists to scrub them after a rotation.

## Usage

```powershell
# Audit: report occurrences, change nothing
pwsh -File D:\Projects\workbench\scripts\Invoke-Context7StateScrub.ps1

# Scrub: redact in place, then verify zero occurrences remain
pwsh -File D:\Projects\workbench\scripts\Invoke-Context7StateScrub.ps1 -Mode Scrub

# Scrub while Codex is running: close the GUI first, relaunch after
pwsh -File D:\Projects\workbench\scripts\Invoke-Context7StateScrub.ps1 -Mode Scrub -CloseAndRelaunchCodex
```

The Codex home defaults to `~\.codex`; override with `-CodexHome`. The JSON
report defaults to `$env:LOCALAPPDATA\Context7StateScrub\context7-scrub-report.json`
and must live outside the Codex home (override with `-ReportPath`).

Requirements: PowerShell 7 and ripgrep (`winget install
BurntSushi.ripgrep.MSVC`, or pass `-RipgrepPath`).

## Safety properties

- **Keys are never exposed.** The report and all output contain only
  12-character SHA-256 fingerprints (`DistinctFingerprints`, `Fingerprints`),
  never key values or file paths. Redacted text reads
  `[REDACTED_CONTEXT7_KEY:<fingerprint>]` so each marker maps to a rotated
  key without revealing it.
- **Validate-all-before-changing-any.** Every candidate file is parsed
  (strict UTF-8, valid JSON/JSONL) before any file is modified; one corrupt
  target aborts the whole run with nothing changed.
- **Atomic, metadata-preserving writes.** Replacements go through a temp
  file + `MoveFileEx` replace and preserve BOM, line endings, timestamps,
  attributes, and ACLs. No secret-bearing backup file is ever created.
- **Path hardening.** Reparse points (junctions/symlinks), UNC and
  device-namespace paths, trailing-dot/space components, and alternate data
  streams are rejected for every input and output path.
- **Fail closed.** Exit 0 means the report was written with `Success=true`;
  anything else throws. A single-instance mutex blocks concurrent scrubs,
  and Scrub mode re-scans afterwards and fails unless zero occurrences
  remain.

## Idempotency

Audit never writes anything but the report. Scrub replaces only matched key
text, so a second run finds zero occurrences and verifies clean. The
`-CloseAndRelaunchCodex` relaunch only happens when a close was actually
requested.

## Tests

`tests/Context7StateScrub.Tests.ps1` (Pester 5.x) covers the path-hardening
rejections, atomic-write behavior, metadata preservation, the mutex, and the
close/relaunch flow. Run:

```powershell
Invoke-Pester -Path D:\Projects\workbench\tests\Context7StateScrub.Tests.ps1 -Output Detailed
```
