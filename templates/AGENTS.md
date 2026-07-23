# PROJECT KNOWLEDGE BASE

## OVERVIEW

<one paragraph: what this project is, what it deliberately is NOT>

## STRUCTURE

```text
./
|-- src/ or <package>/   # application code
|-- tests/               # test suite
|-- docs/                # runbooks and decisions
`-- AGENTS.md
```

## WHERE TO LOOK

| Task | Location | Notes |
| --- | --- | --- |
| <entry point> | <path> | <note> |

## CONVENTIONS

- <API surface or behavior that must be preserved>
- <testing rule: what kind of change requires which tests>
- <dependency rule: stdlib-first, pinned versions, etc.>

## ANTI-PATTERNS

- <things this project must never do, one per line>

## COMMANDS

```bash
<lint command>
<test command>
<build command>
```

## REVIEW GUIDELINES

Blocking findings for reviewers (human or AI):

- <auth/security invariants>
- <data-loss or idempotency invariants>
- <missing tests for risky surfaces>
