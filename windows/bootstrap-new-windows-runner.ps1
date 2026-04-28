#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Altosec Email Scheduler — Windows: WSL2 Ubuntu install + mirrored networking + firewall.

.DESCRIPTION
  1. Enables WSL2 and installs Ubuntu if not already present (idempotent).
  2. Writes networkingMode=mirrored to %USERPROFILE%\.wslconfig.
  3. Restarts WSL2 so mirrored networking takes effect.
  4. Opens Windows Firewall inbound rule TCP 2026.
  5. Sets Machine env ALTOSEC_EMAIL_DEPLOY_DIR.
  6. Runs the Linux bootstrap inside WSL2 Ubuntu (installs Docker Engine + runner).

.PARAMETER DeployDir
  Windows-side deploy path. Default: C:\altosec-deploy-email
#>
[CmdletBinding()]
param(
    [string] $DeployDir = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($DeployDir)) {
    $line = Read-Host 'Deploy directory (ALTOSEC_EMAIL_DEPLOY_DIR) [C:\altosec-deploy-email]'
    $DeployDir = if ([string]::IsNullOrWhiteSpace($line)) { 'C:\altosec-deploy-email' } else { $line.Trim() }
}

# ── 1. WSL2 feature + Ubuntu-24.04 install (idempotent) ──────────────────────
$ubuntuDistro = 'Ubuntu-24.04'
$distros = wsl --list --quiet 2>$null | ForEach-Object { $_ -replace "`0", '' } | Where-Object { $_ }
$found = $distros | Where-Object { $_ -eq $ubuntuDistro } | Select-Object -First 1

if (-not $found) {
    Write-Host "$ubuntuDistro not found. Installing (this may take a few minutes)..."
    wsl --install -d $ubuntuDistro --no-launch
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --install -d $ubuntuDistro failed (exit $LASTEXITCODE). Ensure Windows is up to date."
    }
    Write-Host "$ubuntuDistro installed."
} else {
    Write-Host "$ubuntuDistro already installed. Skipping."
}

# ── 2. WSL2 mirrored networking ───────────────────────────────────────────────
$WslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'
if (Test-Path $WslConfigPath) {
    $existing = Get-Content $WslConfigPath -Raw -ErrorAction SilentlyContinue
    if ($existing -notmatch 'networkingMode\s*=\s*mirrored') {
        if ($existing -match '\[wsl2\]') {
            (Get-Content $WslConfigPath) | ForEach-Object {
                $_
                if ($_ -match '^\[wsl2\]') { 'networkingMode=mirrored' }
            } | Set-Content $WslConfigPath
        } else {
            Add-Content $WslConfigPath "`n[wsl2]`nnetworkingMode=mirrored"
        }
        Write-Host "Added networkingMode=mirrored to $WslConfigPath."
    } else {
        Write-Host "WSL2 mirrored networking already set in $WslConfigPath."
    }
} else {
    [System.IO.File]::WriteAllText(
        $WslConfigPath,
        "[wsl2]`nnetworkingMode=mirrored`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-Host "Created $WslConfigPath with networkingMode=mirrored."
}

# ── 3. Disable systemd in WSL2 (causes boot failure on VPS without nested-virt) ──
# Docker and the runner work fine without systemd (SysV fallback + nohup).
Write-Host 'Ensuring systemd is disabled in WSL2 Ubuntu...'
wsl -d $ubuntuDistro -u root -- bash -c "sed -i 's/^systemd=true/#systemd=true/' /etc/wsl.conf 2>/dev/null; echo 'wsl.conf: systemd disabled'"

# ── 4. Restart WSL2 so mirrored networking + systemd change both take effect ──
Write-Host 'Restarting WSL2...'
wsl --shutdown
Start-Sleep -Seconds 3

# ── 4. Windows Firewall — TCP 2026 inbound ────────────────────────────────────
$fw = 'AltosecEmailSchedulerHTTP2026'
if (-not (Get-NetFirewallRule -Name $fw -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $fw `
        -DisplayName 'Altosec Email Scheduler API (TCP 2026 inbound)' `
        -Direction Inbound -Protocol TCP -LocalPort 2026 -Action Allow -Profile Any | Out-Null
    Write-Host "Created firewall rule $fw (TCP 2026)."
} else {
    Write-Host "Firewall rule $fw already exists."
}

# ── 5. Machine environment variable ──────────────────────────────────────────
[Environment]::SetEnvironmentVariable('ALTOSEC_EMAIL_DEPLOY_DIR', $DeployDir.Trim(), 'Machine')
[Environment]::SetEnvironmentVariable('ALTOSEC_DEPLOY_HTTP_ONLY', 'true', 'Machine')
Write-Host "Machine env: ALTOSEC_EMAIL_DEPLOY_DIR=$($DeployDir.Trim())  ALTOSEC_DEPLOY_HTTP_ONLY=true"

# ── 6. Run Linux bootstrap inside WSL2 Ubuntu ────────────────────────────────
Write-Host ''
Write-Host 'Launching Linux bootstrap inside WSL2 Ubuntu...'
wsl -d $ubuntuDistro -u root -- bash -c "curl -fsSL https://raw.githubusercontent.com/alto-sec/Altosec-email-scheduler-scripts/main/linux/bootstrap-email-scheduler-runner.sh | bash"

# ── 7. Remove any leftover Task Scheduler watchdog from previous installs ─────
$taskName = 'AltosecEmailSchedulerRunner'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed Task Scheduler task '$taskName'."
}
