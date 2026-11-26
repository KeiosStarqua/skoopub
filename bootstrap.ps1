# bootstrap.ps1 - backward-compatible entry point.
# The implementation lives in core\bootstrap.ps1; this wrapper only forwards
# arguments so existing `.\bootstrap.ps1` usage keeps working.
[CmdletBinding()]
param(
    [switch]$ForceUniKey,
    [switch]$SkipGhLogin
)

$ErrorActionPreference = 'Stop'
$target = Join-Path $PSScriptRoot 'core\bootstrap.ps1'
& $target @PSBoundParameters
exit $LASTEXITCODE
