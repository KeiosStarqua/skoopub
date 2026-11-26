#Requires -Version 5.1
<#
.SYNOPSIS
    Set the git author name and email used for commits.

.DESCRIPTION
    Sets `user.name` to Keios and `user.email` to git@taquangkhoi.com by
    default. Writes to the global git config so every repository uses the same
    identity; pass -Local to set it only for the current repository. Re-running
    the script is safe and only writes values that differ.

.PARAMETER Name
    Author name to store (default: Keios).

.PARAMETER Email
    Author email to store (default: git@taquangkhoi.com).

.PARAMETER Local
    Write to the repository config instead of the global config.

.EXAMPLE
    .\setup-git-identity.ps1

.EXAMPLE
    .\setup-git-identity.ps1 -Local
#>
[CmdletBinding()]
param(
    [string]$Name = 'Keios',
    [string]$Email = 'git@taquangkhoi.com',
    [switch]$Local
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git was not found on PATH; install git before setting the author identity.'
}

$scope = if ($Local) { '--local' } else { '--global' }
$label = if ($Local) { 'repository' } else { 'global' }

function Get-GitValue([string]$Key) {
    # cmd /c + 2>&1 keeps a missing key from becoming a terminating
    # NativeCommandError under PowerShell 5.1's $ErrorActionPreference = 'Stop'.
    $output = & cmd /c "git config $scope --get $Key 2>&1" | Out-String
    if ($LASTEXITCODE -eq 0) { return $output.Trim() }
    return $null
}

foreach ($entry in @(
    @{ Key = 'user.name';  Value = $Name },
    @{ Key = 'user.email'; Value = $Email }
)) {
    $key = $entry.Key
    $value = $entry.Value
    $current = Get-GitValue -Key $key
    if ($current -eq $value) {
        Write-Host "git $label $key already: $value" -ForegroundColor DarkGray
        continue
    }

    & git config $scope $key $value
    if ($LASTEXITCODE -ne 0) {
        throw "git config $scope $key $value failed with exit code $LASTEXITCODE"
    }
    Write-Host "Set git $label $key -> $value" -ForegroundColor Green
}

Write-Host "Commits will use: $Name <$Email>" -ForegroundColor Green
