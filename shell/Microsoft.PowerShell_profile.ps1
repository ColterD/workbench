# workbench PowerShell 7 profile
# Installed to $PROFILE by bootstrap/Install-Workbench.ps1

# --- PATH repairs (tools that install off-PATH) ---
$pathExtras = @(
    (Join-Path $env:LOCALAPPDATA 'Workbench\bin'),                 # standalone docker CLI
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'),         # pwsh shims
    (Join-Path $env:USERPROFILE '.local\bin')                      # uv / pipx-style tools
)
foreach ($extra in $pathExtras) {
    if ((Test-Path $extra) -and ($env:PATH -notlike "*$extra*")) { $env:PATH = "$extra;$env:PATH" }
}

# --- Aliases ---
Set-Alias g git
function gs { git status --short --branch }
function gl { git log --oneline -15 }
function gd { git diff }
function projects { Set-Location D:\Projects }

# --- Quality of life ---
Set-PSReadLineOption -PredictionSource History -ErrorAction SilentlyContinue
$env:LESS = 'FRX'

# Machine-local overrides (never committed; secrets belong here or in User env vars)
$localProfile = "$PROFILE.local.ps1"
if (Test-Path $localProfile) { . $localProfile }
