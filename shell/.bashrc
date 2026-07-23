# workbench Git Bash config
# Installed to ~/.bashrc by bootstrap/Install-Workbench.ps1

# --- PATH repairs ---
[ -d "$LOCALAPPDATA/Workbench/bin" ] && export PATH="$LOCALAPPDATA/Workbench/bin:$PATH"
[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"
PWSH_WINAPPS="$LOCALAPPDATA/Microsoft/WindowsApps"
[ -f "$PWSH_WINAPPS/pwsh.exe" ] && alias pwsh="$PWSH_WINAPPS/pwsh.exe"

# --- Aliases ---
alias g=git
alias gs='git status --short --branch'
alias gl='git log --oneline -15'
alias gd='git diff'
alias ll='ls -lah'
alias projects='cd /d/Projects'

# --- Quality of life ---
export LESS=FRX
export EDITOR=vim

# Machine-local overrides (never committed)
[ -f "$HOME/.bashrc.local" ] && . "$HOME/.bashrc.local"
