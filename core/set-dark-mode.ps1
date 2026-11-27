#Requires -Version 5.1
<#
.SYNOPSIS
    Checks the current Windows theme and turns on Dark Mode for apps and system.

.DESCRIPTION
    Reads HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize:
    AppsUseLightTheme and SystemUsesLightTheme. When either value is 1 (light),
    both are set to 0 (dark); when both are already 0 the script does nothing,
    so it is safe to run on every bootstrap. A best-effort
    WM_SETTINGCHANGE("ImmersiveColorSet") broadcast asks running apps to reload
    the theme. Everything is per-user (HKCU), so no admin is required.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor DarkGray }

$key   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$names = @('AppsUseLightTheme', 'SystemUsesLightTheme')

Write-Step 'Checking Windows Dark Mode'

$current = @{}
foreach ($name in $names) {
    $current[$name] = (Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction SilentlyContinue).$name
}

if ($current['AppsUseLightTheme'] -eq 0 -and $current['SystemUsesLightTheme'] -eq 0) {
    Write-Ok 'Dark Mode is already on (apps + system) - nothing to change'
    return
}

if (-not (Test-Path -LiteralPath $key)) {
    New-Item -Path $key -Force | Out-Null
}
foreach ($name in $names) {
    New-ItemProperty -LiteralPath $key -Name $name -PropertyType DWord -Value 0 -Force | Out-Null
}
Write-Ok 'Dark Mode enabled (apps + system)'

# Ask running apps to pick up the new theme. Cosmetic: never fail a bootstrap.
try {
    Add-Type -Namespace Skoop -Name ThemeNativeMethods -MemberDefinition @'
        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam,
            string lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
'@ -ErrorAction Stop
    $result = [IntPtr]::Zero
    $null = [Skoop.ThemeNativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff, 0x1A, [IntPtr]::Zero, 'ImmersiveColorSet', 0x2, 2000, [ref]$result)
    Write-Ok 'notified running apps of the theme change'
} catch {
    Write-Host "    Theme-change notification skipped (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
}
