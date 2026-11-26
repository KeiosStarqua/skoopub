# setup-nushell.ps1
# Make Nushell easy to launch from cmd.exe, matching the `n` alias in profile.ps1.
# Creates %LOCALAPPDATA%\skoop\nu-autostart.cmd (a doskey macro) and adds it to
# HKCU\Software\Microsoft\Command Processor\AutoRun without replacing existing
# AutoRun entries. `-Remove` undoes both.
#
#   powershell -ExecutionPolicy Bypass -File .\setup-nushell.ps1
#   powershell -ExecutionPolicy Bypass -File .\setup-nushell.ps1 -Remove
[CmdletBinding()]
param(
    # Remove the cmd AutoRun entry and the helper .cmd file.
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$keyPath = 'HKCU:\Software\Microsoft\Command Processor'
$valueName = 'AutoRun'
$launcherDir = Join-Path $env:LOCALAPPDATA 'skoop'
$launcher = Join-Path $launcherDir 'nu-autostart.cmd'
$launcherCommand = '"' + $launcher + '"'

function Get-AutoRun {
    $item = Get-ItemProperty -LiteralPath $keyPath -Name $valueName -ErrorAction SilentlyContinue
    if ($null -eq $item) { return '' }
    return [string]$item.$valueName
}

if ($Remove) {
    $existing = Get-AutoRun
    if ($existing) {
        $kept = @($existing -split '\s+&\s+' | Where-Object { $_ -and $_ -notlike "*$launcher*" })
        if ($kept.Count) {
            New-ItemProperty -LiteralPath $keyPath -Name $valueName -PropertyType String -Value ($kept -join ' & ') -Force | Out-Null
            Write-Host "Removed Nushell helper from $valueName; kept: $($kept -join ' & ')"
        } else {
            Remove-ItemProperty -LiteralPath $keyPath -Name $valueName -ErrorAction SilentlyContinue
            Write-Host "Removed $valueName (no entries left)."
        }
    }
    if (Test-Path -LiteralPath $launcher) {
        Remove-Item -LiteralPath $launcher -Force
        Write-Host "Removed $launcher"
    }
    return
}

New-Item -ItemType Directory -Force -Path $launcherDir | Out-Null
$lines = @(
    '@echo off',
    'rem skoop: `n` starts Nushell in cmd.exe (managed by setup-nushell.ps1).',
    'doskey n=nu $*'
)
Set-Content -LiteralPath $launcher -Value $lines -Encoding ASCII
Write-Host "Wrote $launcher"

if (-not (Test-Path -LiteralPath $keyPath)) {
    New-Item -Path $keyPath -Force | Out-Null
}

$existing = Get-AutoRun
if (-not $existing) {
    $updated = $launcherCommand
} elseif ($existing -like "*$launcher*") {
    $updated = $existing
} else {
    $updated = $existing + ' & ' + $launcherCommand
}

if ($updated -ne $existing) {
    New-ItemProperty -LiteralPath $keyPath -Name $valueName -PropertyType String -Value $updated -Force | Out-Null
    Write-Host "Set $valueName -> $updated"
} else {
    Write-Host "$valueName already includes the Nushell helper."
}

Write-Host 'New cmd.exe windows will have the `n` alias for Nushell.' -ForegroundColor Green
