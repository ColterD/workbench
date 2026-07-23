# OpenBao Cutover Runbook

> Sanitized import: `vault.internal` is a placeholder for the real internal
> vault hostname; substitute your own endpoint when using this runbook.

Last updated: 2026-03-06

## Objective

Migrate from current Vault runtime to OpenBao while keeping public endpoint stable:

- Public URL remains `https://vault.internal:8200`
- Cloudflare tunnel origin target is switched during cutover
- AppRole clients keep using Vault-compatible HTTP API paths

## Observed current risks

1. Runtime image is `hashicorp/vault:latest` (unpinned, non-OpenBao)
2. Auto-unseal helper currently includes unseal key material in env vars

These require remediation and credential rotation as part of cutover.

## Preconditions

- Back up current KV data and policies
- Export AppRole, auth method, and policy definitions
- Prepare OpenBao container with pinned tag
- Prepare rollback mapping in cloudflared tunnel

## Migration phases

### Phase 1: Parallel OpenBao bootstrap

1. Start OpenBao on private origin port
2. Initialize and unseal with secure handling
3. Import policies/auth methods
4. Import KV data under same paths (`secret/data/cicd/*`, etc.)
5. Run read/write parity tests

### Phase 2: Client auth verification

1. Validate AppRole login from CI runtime
2. Validate fetch of:
   - `secret/data/cicd/zai`
   - `secret/data/cicd/github`
   - `secret/data/cicd/gitlab`
   - `secret/data/cicd/sonarqube`
3. Confirm denied access for out-of-scope paths

### Phase 3: URL-preserving cutover

1. Switch cloudflared origin route for `vault.internal` to OpenBao target
2. Validate `/v1/sys/health` and AppRole login
3. Run CI smoke test using `auto-fix-export`

### Phase 4: Post-cutover hardening

1. Rotate all credentials:
   - AppRole role_id/secret_id
   - CI integration tokens
   - any prior unseal/recovery material exposed to automation
2. Remove legacy Vault containers and scripts after rollback window
3. Verify no plaintext unseal keys remain in runtime env

## Rollback

If cutover validation fails:

1. Repoint cloudflared origin for `vault.internal` back to prior Vault target
2. Re-run CI secret fetch smoke checks
3. Keep OpenBao state for forensics and retry

## Done criteria

- `vault.internal` is backed by OpenBao
- CI AppRole auth succeeds for required paths
- No plaintext unseal key material in container env
- Legacy Vault runtime is retired
