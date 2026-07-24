# Secrets inventory (OpenBao/Vault layer)

The rule from [secrets-policy.md](secrets-policy.md) — env var NAMES in git,
values never — has a canonical value store behind it: the owner's
OpenBao/Vault instance (migrated per [openbao-cutover.md](openbao-cutover.md)).
`scripts/Sync-Secrets.ps1` pulls values from the vault into Windows
user-level environment variables, driven by `scripts/sync-secrets.map.json`,
which holds **names, vault paths, and keys only — never values**.

## Where things live

| What | Where |
| --- | --- |
| Secret values | OpenBao/Vault kv-v2 (the only canonical store) |
| Inventory (name → vault path + key) | `scripts/sync-secrets.map.json` (tracked, values-free) |
| Working copies of values | Windows user-level env vars, set by the sync |
| Vault address | `VAULT_ADDR` env var (process or user-level) — local-only, NEVER committed |
| Vault token | `VAULT_TOKEN` env var only — never persisted by the sync, never printed, never logged |

## Using it

```powershell
# What is set locally, what is missing, is the vault reachable? (always exit 0)
pwsh -File D:\Projects\workbench\scripts\Sync-Secrets.ps1 -Check

# Pull every entry from the vault into user-level env vars
pwsh -File D:\Projects\workbench\scripts\Sync-Secrets.ps1

# Preview without changing anything
pwsh -File D:\Projects\workbench\scripts\Sync-Secrets.ps1 -WhatIf
```

Behavior worth knowing:

- **Idempotent**: entries already in sync are reported and left untouched;
  re-running is always safe. Nothing is backed up — values only ever flow
  vault → env var.
- **Graceful degrade**: no `VAULT_ADDR`, unreachable vault, or no
  `VAULT_TOKEN` prints a clear warning and exits 0 with nothing applied.
  Nonzero exits mean something actionable: 1 = at least one entry failed to
  apply (each failure is isolated and warned by name), 2 = the map is
  invalid.
- **Auth transport**: prefers the `bao` or `vault` CLI when installed;
  otherwise plain HTTPS REST against the kv-v2 API
  (`GET $VAULT_ADDR/v1/<mount>/data/<path>`). The token goes only to the
  vault, in the `X-Vault-Token` header or the CLI's own env.
- **Output discipline**: names and set/masked status only. A value is never
  echoed, logged, or written to disk by the sync.

## Adding a new secret

1. **Vault first.** Write the value into the vault:
   `bao kv put secret/tools/myservice api-key=<value>` (or the UI).
2. **Map entry.** Add the env var name to `scripts/sync-secrets.map.json`
   with `path`, `key`, and a `description` naming the consumer. Unsure the
   path is right? Add `"verify": true` — the sync warns about unverified
   entries instead of failing, and you clear the flag once confirmed.
3. **Sync.** Run `Sync-Secrets.ps1` (or `-WhatIf` first), then restart
   shells so the new user-level env var loads.
4. **Reference the NAME** in scripts/docs, never the value — unchanged from
   secrets-policy.md.

## New machines

The bootstrap (`bootstrap/Install-Workbench.ps1`) checks that `VAULT_ADDR`
is configured and reports MANUAL when it is not — it never sets it, because
the real address must never be committed. On a fresh machine: set
`VAULT_ADDR` and `VAULT_TOKEN` locally, run `Sync-Secrets.ps1`, and the
rest of the secrets layer (SNYK_TOKEN and friends) comes down from the
vault. See docs/new-machine.md and docs/restore-after-wipe.md.
