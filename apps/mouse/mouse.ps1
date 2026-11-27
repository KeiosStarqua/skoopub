#Requires -Version 5.1
<#
.SYNOPSIS
    skoopub mouse: capture/fix random inverted mouse-wheel scrolling.

.EXAMPLE
    .\apps\mouse\mouse.ps1 diagnose -Seconds 30
    .\apps\mouse\mouse.ps1 fix            # starts the correction silently
    .\apps\mouse\mouse.ps1 restore        # stops it again
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('diagnose', 'monitor', 'fix', 'restore', 'status', 'dpi', 'install', 'driver')]
    [string]$Command,
    [int]$Seconds = 30,
    [int]$Dpi = 1200,
    [string]$Out,
    [string]$From,
    [string]$Expect,
    [switch]$Adaptive,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Build,
    [switch]$Interactive,
    [switch]$DebugRaw,
    [switch]$Cues,
    [string]$Repo = 'KeiosStarqua/skoopub',
    [string]$Version = '',
    [ValidateSet('inspect', 'stack', 'filters', 'integrity', 'events', 'report')]
    [string]$Action = 'report',
    [string]$MouseVidPid = 'VID_046D&PID_C08F',
    [int]$Days = 7,
    [switch]$Deep,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:LOCALAPPDATA 'skoop\mouse'
$exe = Join-Path $installDir 'skoopub-mouse.exe'
$configure = Join-Path $PSScriptRoot 'configure.ps1'
$driverScript = Join-Path $PSScriptRoot 'driver.ps1'

if ($Command -eq 'driver') {
    if (-not (Test-Path -LiteralPath $driverScript)) { throw "driver.ps1 not found at $driverScript" }
    & $driverScript -Action $Action -MouseVidPid $MouseVidPid -Days $Days -Deep:$Deep -Json:$Json
    return
}

if ($Command -eq 'install') {
    & $configure -Repo $Repo -Version $Version -Force:$Force -Build:$Build
    return
}

if (-not (Test-Path -LiteralPath $exe)) {
    Write-Host '==> skoopub-mouse not installed yet - fetching the latest release'
    $null = & $configure -Repo $Repo -Version $Version -Force:$Force -Build:$Build
}
if (-not (Test-Path -LiteralPath $exe)) { throw "skoopub-mouse executable not found at $exe" }

$exeArgs = @($Command)
switch ($Command) {
    'diagnose' {
        $exeArgs += @('--seconds', "$Seconds")
        if ($DebugRaw) { $exeArgs += '--debug-raw' }
        if ($Cues) { $exeArgs += '--cues' }
        if ($Expect) { $exeArgs += @('--expect', $Expect) }
        if ($Out) { $exeArgs += @('--out', $Out) }
    }
    'monitor' {
        $exeArgs += @('--seconds', "$Seconds")
        if ($Expect) { $exeArgs += @('--expect', $Expect) }
    }
    'fix' {
        if ($Adaptive) { $exeArgs += '--adaptive' }
        if ($DryRun) { $exeArgs += '--dry-run' }
        if ($Force) { $exeArgs += '--force' }
        if ($From) { $exeArgs += @('--from', $From) }
    }
    'dpi' {
        $exeArgs += @('--value', "$Dpi")
        if ($DryRun) { $exeArgs += '--dry-run' }
    }
}

if ($Command -eq 'fix' -and -not $Interactive) {
    # A global WH_MOUSE_LL hook needs a live message loop. Run it hidden and
    # let `restore` terminate it; logs and the report stay in %LOCALAPPDATA%.
    $quoted = (@($exeArgs) | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $process = Start-Process -FilePath $exe -ArgumentList $quoted -WindowStyle Hidden -PassThru
    Write-Host "Mouse wheel correction started (PID $($process.Id))."
    Write-Host 'Run .\apps\mouse\mouse.ps1 restore to stop it.'
    return
}

& $exe @exeArgs
