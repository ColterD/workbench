<#
.SYNOPSIS
    Pattern-based secret scan for a project directory. Scans tracked files,
    untracked-non-ignored files, and staged content when inside a git repo.
    Exits 1 on any hit. Optional allowlist: <root>\.secret-scan-allow
    (one literal allowed value per line; blank lines and lines starting
    with '#' are ignored).
.PARAMETER Path
    Directory to scan.
.PARAMETER Staged
    Scan only staged git content (for pre-commit use). Requires -Path to
    be inside a git repository. Content is read from the index (git show),
    so uncommitted working-tree edits to unstaged hunks are not scanned.
.EXAMPLE
    pwsh -File Invoke-SecretScan.ps1 -Path D:\Projects\screenarr
.EXAMPLE
    pwsh -File Invoke-SecretScan.ps1 -Path . -Staged
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$Staged
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $Path).Path

# name -> regex; names make hit output self-explanatory
$patterns = [ordered]@{
    # --- generic / structural ---
    # [ \t]* (not \s*) so matches cannot hop across lines in env files;
    # attribute chains (self.x, settings.x) are excluded via $patternExclusions
    'generic-credential-assignment' = '(?i)(api[_-]?key|access[_-]?key|secret[_-]?key|secret|password|passwd|token)[ \t]*[=:][ \t]*["'']?[A-Za-z0-9._~+/=-]{16,}'
    # quoted-key JSON/YAML form the pattern above cannot reach ("key": "value");
    # lookaheads skip env-var-NAME values (SOME_API_KEY: all caps + underscore)
    # and values starting with placeholder words (your-/change/example/...)
    'json-credential-assignment'    = '(?i)"[A-Za-z0-9_.-]*(?:api[_-]?key|access[_-]?key|secret[_-]?key|client[_-]?secret|secret|password|passwd|token)[A-Za-z0-9_.-]*"[ \t]*:[ \t]*"(?!(?=[A-Za-z0-9_]*_)[A-Za-z0-9_]{16,}")(?!(?i:your|change|example|dummy|placeholder|xxxx|fake))[A-Za-z0-9._~+/=-]{16,}"'
    'authorization-header'          = '(?i)(?:proxy-)?authorization[ \t]*:[ \t]*(?:basic|bearer|digest|negotiate|ntlm)[ \t]+[A-Za-z0-9._~+/=-]{8,}'
    'cookie-header'                 = '(?i)\b(?:set-)?cookie[ \t]*:[ \t]*[^\s=;,]{1,64}=[A-Za-z0-9._~+/=-]{16,}'
    'private-key-block'             = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'bearer-token'                  = '(?i)bearer\s+[A-Za-z0-9._~+/=-]{20,}'
    'jwt'                           = 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    'uri-embedded-credentials'      = '[a-z][a-z0-9+.-]{2,}://[^/\s:@]{1,64}:[^/\s@]{3,}@'
    'kubeconfig-client-key'         = 'client-key-data:\s*[A-Za-z0-9+/=]{40,}'
    'azure-storage-account-key'     = '(?i)AccountKey=[A-Za-z0-9+/=]{40,}'
    'age-secret-key'                = 'AGE-SECRET-KEY-1[A-Z0-9]{58}'
    # --- git platforms ---
    'github-pat-classic'            = 'ghp_[A-Za-z0-9]{20,}'
    'github-pat-finegrained'        = 'github_pat_[A-Za-z0-9_]{20,}'
    'github-oauth-token'            = 'gh[ousr]_[A-Za-z0-9]{20,}'
    'gitlab-pat'                    = 'glpat-[A-Za-z0-9_-]{20,}'
    'gitlab-runner-token'           = 'glrt-[A-Za-z0-9_-]{20,}'
    'gitlab-ci-job-token'           = 'glcbt-[A-Za-z0-9_-]{20,}'
    # --- AI providers ---
    'openai-api-key'                = 'sk-[A-Za-z0-9]{20,}'
    'openai-project-key'            = 'sk-proj-[A-Za-z0-9_-]{20,}'
    'anthropic-api-key'             = 'sk-ant-[A-Za-z0-9_-]{20,}'
    # other sk- providers with separators (sk-or-v1-..., etc.); the lookaheads
    # keep sk-ant-/sk-proj- and pure-alnum keys reported by their own patterns
    'generic-sk-key'                = 'sk-(?!ant-|proj-)(?![A-Za-z0-9]{20,})[A-Za-z0-9][A-Za-z0-9._-]{18,}'
    'huggingface-token'             = 'hf_[A-Za-z0-9]{30,}'
    'groq-api-key'                  = 'gsk_[A-Za-z0-9]{20,}'
    'replicate-api-token'           = 'r8_[A-Za-z0-9]{20,}'
    # --- cloud / infra ---
    'aws-access-key-id'             = 'AKIA[0-9A-Z]{16}'
    'aws-presigned-url'             = '[?&](?:X-Amz-Signature|X-Amz-Credential|X-Amz-Security-Token|AWSAccessKeyId|Signature)=[A-Za-z0-9%._~+/=-]{8,}'
    'digitalocean-pat'              = 'dop_v1_[a-f0-9]{64}'
    'docker-hub-pat'                = 'dckr_pat_[A-Za-z0-9_-]{20,}'
    'supabase-pat'                  = 'sbp_[a-f0-9]{40}'
    'planetscale-token'             = 'pscale_(?:tkn|pw)_[A-Za-z0-9_-]{20,}'
    'neon-api-key'                  = 'napi_[a-z0-9]{20,}'
    'doppler-token'                 = 'dp\.st\.[A-Za-z0-9._-]{20,}'
    # --- payments ---
    'stripe-key'                    = '[sr]k_(?:live|test)_[A-Za-z0-9]{16,}'
    'square-token'                  = 'sq0(?:atp|csp)-[A-Za-z0-9_-]{20,}'
    # --- package registries ---
    'npm-access-token'              = 'npm_[A-Za-z0-9]{36}'
    'pypi-api-token'                = 'pypi-[A-Za-z0-9_-]{20,}'
    # --- comms / webhooks ---
    'slack-token'                   = 'xox[abpors]-[A-Za-z0-9-]{10,}'
    'slack-webhook'                 = 'https://hooks\.slack\.com/services/T[A-Z0-9]{6,}/B[A-Z0-9]{6,}/[A-Za-z0-9]{16,}'
    'discord-webhook'               = 'https://(?:canary\.|ptb\.)?discord(?:app)?\.com/api/webhooks/\d{17,20}/[A-Za-z0-9_-]{20,}'
    'telegram-bot-token'            = '\d{8,10}:[A-Za-z0-9_-]{35}'
    'sendgrid-api-key'              = 'SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}'
    'twilio-api-key'                = 'SK[0-9a-fA-F]{32}'
    # --- SaaS tools ---
    'google-api-key'                = 'AIza[0-9A-Za-z_-]{35}'
    'google-oauth-client-secret'    = 'GOCSPX-[A-Za-z0-9_-]{20,}'
    'shopify-token'                 = 'shp(?:at|ca|pa|ss)_[a-f0-9]{32}'
    'new-relic-api-key'             = 'NRAK-[A-Z0-9]{27}'
    'okta-ssws-token'               = '(?i)SSWS\s+[A-Za-z0-9_-]{20,}'
    'linear-api-key'                = 'lin_api_[A-Za-z0-9]{40}'
    'notion-token'                  = 'ntn_[A-Za-z0-9]{20,}'
    'figma-token'                   = 'figd_[A-Za-z0-9_-]{20,}'
    'airtable-pat'                  = 'pat[A-Za-z0-9]{14}\.[0-9a-f]{64}'
    'snyk-uat'                      = 'snyk_uat\.[A-Za-z0-9._-]{20,}'
    # --- file-sharing links (decryption key in the fragment) ---
    'mega-nz-link'                  = '(?i)https?://mega\.nz/(?:(?:file|folder)/[A-Za-z0-9_-]{6,}#|#F![A-Za-z0-9_-]{6,}!)[A-Za-z0-9_-]{8,}'
}

$allowlist = @()
$allowFile = Join-Path $root '.secret-scan-allow'
if (Test-Path -LiteralPath $allowFile) {
    $allowlist = @(Get-Content -LiteralPath $allowFile | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and -not $_.TrimStart().StartsWith('#')
    })
}

# Per-pattern exclusions: matches against these are never secrets. Kept narrow
# and pattern-specific so exclusions cannot mask real hits elsewhere.
$patternExclusions = @{
    # attribute/identifier references, not literal values:
    #   secret = self.dashboard_session_secret / token = settings.mediamanager_token
    'generic-credential-assignment' = @('(self|cls|settings|config|conf|app|os|sys|this)\.[A-Za-z0-9_.]')
    # scrubbed/doc references to sk- keys (fixture values, REMOVED-EXPOSED notes)
    'generic-sk-key'                = @('(?i)(fixture|fake|example|dummy|removed|exposed|placeholder|your|xxxx)')
}

# In source code, an UNQUOTED bare identifier / call on the right-hand side is
# a reference, not a literal:  secret = dashboard_session_secret
#   secret = resolve_dashboard_session_secret(settings, store)
# Real literals in code are quoted; env/data files stay strict (no exclusion).
$codeExtensions = @('.py', '.js', '.jsx', '.ts', '.tsx', '.go', '.rs', '.java',
    '.rb', '.cs', '.sh', '.bash', '.ps1', '.psm1', '.psd1', '.c', '.cpp', '.h',
    '.hpp', '.kt', '.swift', '.php')

function Test-Content([string]$Relative, [string]$Text, [Collections.Generic.List[string]]$Hits) {
    $ext = [IO.Path]::GetExtension($Relative).ToLowerInvariant()
    foreach ($name in $patterns.Keys) {
        foreach ($match in [regex]::Matches($Text, $patterns[$name])) {
            if ($name -eq 'generic-credential-assignment' -and
                $codeExtensions -contains $ext -and
                $match.Value -match '[=:][ \t]*[A-Za-z_][A-Za-z0-9_.]*$') { continue }
            $excluded = $false
            if ($patternExclusions.ContainsKey($name)) {
                foreach ($exclusion in $patternExclusions[$name]) {
                    if ($match.Value -match $exclusion) { $excluded = $true; break }
                }
            }
            if ($excluded) { continue }
            $allowed = $false
            foreach ($allowedValue in $allowlist) {
                if ($match.Value.Contains($allowedValue)) { $allowed = $true; break }
            }
            if (-not $allowed) {
                $preview = $match.Value.Substring(0, [Math]::Min(24, $match.Value.Length))
                $Hits.Add("${Relative}: [${name}] ${preview}...")
            }
        }
    }
}

$hits = [Collections.Generic.List[string]]::new()

Push-Location $root
try {
    $isRepo = $null -ne (git rev-parse --show-toplevel 2>$null)

    if ($Staged) {
        if (-not $isRepo) { throw "-Staged requires a git repository at '$Path'." }
        # Staged blobs only, straight from the index.
        # NB: local var must not be named $staged — case-insensitive clash with -Staged
        $stagedFiles = @(git diff --cached --name-only --diff-filter=ACMR)
        foreach ($relative in ($stagedFiles | Sort-Object -Unique)) {
            $blob = git show ":$relative" 2>$null
            if ($null -eq $blob) { continue }
            Test-Content $relative ($blob -join "`n") $hits
        }
        if ($hits.Count -eq 0) { Write-Host "secret scan clean ($($stagedFiles.Count) staged files)" }
    } else {
        # Collect candidate files: git-aware when possible, filesystem otherwise.
        $files = @()
        if ($isRepo) {
            $files = @(git ls-files) + @(git ls-files --others --exclude-standard)
        } else {
            $files = @(Get-ChildItem -Recurse -File | ForEach-Object {
                $_.FullName.Substring($root.Length).TrimStart('\', '/')
            })
        }
        foreach ($relative in ($files | Sort-Object -Unique)) {
            $full = Join-Path $root $relative
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            Test-Content $relative ([IO.File]::ReadAllText($full)) $hits
        }
        if ($hits.Count -eq 0) { Write-Host "secret scan clean ($($files.Count) files)" }
    }
} finally { Pop-Location }

if ($hits.Count -gt 0) {
    [Console]::Error.WriteLine("secret scan found $($hits.Count) potential hit(s):")
    $hits | ForEach-Object { [Console]::Error.WriteLine("  $_") }
    exit 1
}
exit 0
